# Payjp Ruby bindings
# API spec at https://pay.jp/docs/api
require 'cgi'
require 'openssl'
require 'rbconfig'
require 'set'
require 'socket'

require 'rest-client'
require 'json'
require 'base64'

# Version
require 'payjp/version'

# API operations
require 'payjp/api_operations/create'
require 'payjp/api_operations/update'
require 'payjp/api_operations/delete'
require 'payjp/api_operations/list'
require 'payjp/api_operations/request'

# Resources
require 'payjp/util'
require 'payjp/payjp_object'
require 'payjp/api_resource'
require 'payjp/list_object'
require 'payjp/account'
require 'payjp/customer'
require 'payjp/charge'
require 'payjp/plan'
require 'payjp/token'
require 'payjp/event'
require 'payjp/transfer'
require 'payjp/card'
require 'payjp/subscription'

# Errors
require 'payjp/errors/payjp_error'
require 'payjp/errors/api_error'
require 'payjp/errors/api_connection_error'
require 'payjp/errors/card_error'
require 'payjp/errors/invalid_request_error'
require 'payjp/errors/authentication_error'

module Payjp
  @api_base = 'https://api.pay.jp'

  class << self
    attr_accessor :api_key, :api_base, :api_version, :connect_base, :uploads_base
  end

  def self.api_url(url = '', api_base_url = nil)
    (api_base_url || @api_base) + url
  end

  def self.request(method, url, api_key, params = {}, headers = {}, api_base_url = nil)
    api_base_url ||= @api_base

    unless api_key ||= @api_key
      raise AuthenticationError.new('No API key provided. ' \
        'Set your API key using "Payjp.api_key = <API-KEY>". ' \
        'You can generate API keys from the Payjp web interface. ' \
        'See https://pay.jp/api for details, or email support@pay.jp ' \
        'if you have any questions.')
    end

    if api_key =~ /\s/
      raise AuthenticationError.new('Your API key is invalid, as it contains ' \
        'whitespace. (HINT: You can double-check your API key from the ' \
        'Payjp web interface. See https://pay.jp/api for details, or ' \
        'email support@pay.jp if you have any questions.)')
    end

    request_opts = {}

    params = Util.objects_to_ids(params)
    url = api_url(url, api_base_url)

    case method.to_s.downcase.to_sym
    when :get, :head, :delete
      # Make params into GET parameters
      url += "#{URI.parse(url).query ? '&' : '?'}#{uri_encode(params)}" if params && params.any?
      payload = nil
    else
      if headers[:content_type] && headers[:content_type] == "multipart/form-data"
        payload = params
      else
        payload = uri_encode(params)
      end
    end

    request_opts.update(:headers => request_headers(api_key).update(headers),
                        :method => method, :open_timeout => 30,
                        :payload => payload, :url => url, :timeout => 80)

    begin
      # $stderr.puts request_opts

      response = execute_request(request_opts)
    rescue SocketError => e
      handle_restclient_error(e, api_base_url)
    rescue NoMethodError => e
      # Work around RestClient bug
      if e.message =~ /\WRequestFailed\W/
        e = APIConnectionError.new('Unexpected HTTP response code')
        handle_restclient_error(e, api_base_url)
      else
        raise
      end
    rescue RestClient::ExceptionWithResponse => e
      if rcode = e.http_code and rbody = e.http_body
        handle_api_error(rcode, rbody)
      else
        handle_restclient_error(e, api_base_url)
      end
    rescue RestClient::Exception, Errno::ECONNREFUSED => e
      handle_restclient_error(e, api_base_url)
    end

    [parse(response), api_key]
  end

  private

  def self.user_agent
    @uname ||= uname
    lang_version = "#{RUBY_VERSION} p#{RUBY_PATCHLEVEL} (#{RUBY_RELEASE_DATE})"

    {
      :bindings_version => Payjp::VERSION,
      :lang => 'ruby',
      :lang_version => lang_version,
      :platform => RUBY_PLATFORM,
      :engine => defined?(RUBY_ENGINE) ? RUBY_ENGINE : '',
      :publisher => 'payjp',
      :uname => @uname,
      :hostname => Socket.gethostname
    }
  end

  def self.uname
    if File.exist?('/proc/version')
      File.read('/proc/version').strip
    else
      case RbConfig::CONFIG['host_os']
      when /linux|darwin|bsd|sunos|solaris|cygwin/i
        _uname_uname
      when /mswin|mingw/i
        _uname_ver
      else
        "unknown platform"
      end
    end
  end

  def self._uname_uname
    (`uname -a 2>/dev/null` || '').strip
  rescue Errno::ENOMEM # couldn't create subprocess
    "uname lookup failed"
  end

  def self._uname_ver
    (`ver` || '').strip
  rescue Errno::ENOMEM # couldn't create subprocess
    "uname lookup failed"
  end

  def self.uri_encode(params)
    Util.flatten_params(params).
      map { |k, v| "#{k}=#{Util.url_encode(v)}" }.join('&')
  end

  def self.request_headers(api_key)
    headers = {
      :user_agent => "Payjp/v1 RubyBindings/#{Payjp::VERSION}",
      :authorization => "Basic #{Base64.encode64("#{api_key}:")}",
      :content_type => 'application/x-www-form-urlencoded'
    }

    headers[:payjp_version] = api_version if api_version

    begin
      headers.update(:x_payjp_client_user_agent => JSON.generate(user_agent))
    rescue => e
      headers.update(:x_payjp_client_raw_user_agent => user_agent.inspect,
                     :error => "#{e} (#{e.class})")
    end
  end

  def self.execute_request(opts)
    RestClient::Request.execute(opts)
  end

  def self.parse(response)
    begin
      # Would use :symbolize_names => true, but apparently there is
      # some library out there that makes symbolize_names not work.
      response = JSON.parse(response.body)
    rescue JSON::ParserError
      raise general_api_error(response.code, response.body)
    end

    Util.symbolize_names(response)
  end

  def self.general_api_error(rcode, rbody)
    APIError.new("Invalid response object from API: #{rbody.inspect} " \
                 "(HTTP response code was #{rcode})", rcode, rbody)
  end

  def self.handle_api_error(rcode, rbody)
    begin
      error_obj = JSON.parse(rbody)
      error_obj = Util.symbolize_names(error_obj)
      error = error_obj[:error] or raise PayjpError.new # escape from parsing

    rescue JSON::ParserError, PayjpError
      raise general_api_error(rcode, rbody)
    end

    case rcode
    when 400, 404
      raise invalid_request_error error, rcode, rbody, error_obj
    when 401
      raise authentication_error error, rcode, rbody, error_obj
    when 402
      raise card_error error, rcode, rbody, error_obj
    else
      raise api_error error, rcode, rbody, error_obj
    end
  end

  def self.invalid_request_error(error, rcode, rbody, error_obj)
    InvalidRequestError.new(error[:message], error[:param], rcode,
                            rbody, error_obj)
  end

  def self.authentication_error(error, rcode, rbody, error_obj)
    AuthenticationError.new(error[:message], rcode, rbody, error_obj)
  end

  def self.card_error(error, rcode, rbody, error_obj)
    CardError.new(error[:message], error[:param], error[:code],
                  rcode, rbody, error_obj)
  end

  def self.api_error(error, rcode, rbody, error_obj)
    APIError.new(error[:message], rcode, rbody, error_obj)
  end

  def self.handle_restclient_error(e, api_base_url = nil)
    api_base_url = @api_base unless api_base_url
    connection_message = "Please check your internet connection and try again. " \
        "If this problem persists, you should check Payjp's service status at " \
        "https://twitter.com/payjpstatus, or let us know at support@pay.jp."

    case e
    when RestClient::RequestTimeout
      message = "Could not connect to Payjp (#{api_base_url}). #{connection_message}"

    when RestClient::ServerBrokeConnection
      message = "The connection to the server (#{api_base_url}) broke before the " \
        "request completed. #{connection_message}"

    when SocketError
      message = "Unexpected error communicating when trying to connect to Payjp. " \
        "You may be seeing this message because your DNS is not working. " \
        "To check, try running 'host pay.jp' from the command line."

    else
      message = "Unexpected error communicating with Payjp. " \
        "If this problem persists, let us know at support@pay.jp."

    end

    raise APIConnectionError.new(message + "\n\n(Network error: #{e.message})")
  end
end
