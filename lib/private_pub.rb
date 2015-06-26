require "digest/sha1"
require "net/http"
require "net/https"

require "private_pub/faye_extension"
require "private_pub/engine" if defined? Rails

module PrivatePub
  class Error < StandardError; end

  class << self
    attr_reader :config

    # Resets the configuration to the default (empty hash)
    def reset_config
      @config = {}
    end

    # Loads the  configuration from a given YAML file and environment (such as production)
    def load_config(filename, environment)
      yaml = YAML.load_file(filename)[environment.to_s]
      raise ArgumentError, "The #{environment} environment does not exist in #{filename}" if yaml.nil?
      yaml.each { |k, v| config[k.to_sym] = v }
    end

    # Publish the given data to a specific channel. This ends up sending
    # a Net::HTTP POST request to the Faye server.
    def publish_to(channel, data)
      publish_message(message(channel, data))
    end

    # Sends the given message hash to the Faye server using Net::HTTP.
    def publish_message(message)
      raise Error, "No server specified, ensure private_pub.yml was loaded properly." unless config[:server]
      url = URI.parse(config[:server])

      form = Net::HTTP::Post.new(url.path.empty? ? '/' : url.path)
      form.set_form_data(:message => message.to_json)

      http = Net::HTTP.new(url.host, url.port)
      http.use_ssl = url.scheme == "https"
      http.start {|h| h.request(form)}
    end

    # Returns a message hash for sending to Faye
    def message(channel, data)
      message = {:channel => channel, :data => {:channel => channel}, :ext => {:private_pub_token => config[:secret_token]}}
      if data.kind_of? String
        message[:data][:eval] = data
      else
        message[:data][:data] = data
      end
      message
    end

    # Returns a subscription hash to pass to the PrivatePub.sign call in JavaScript.
    # Any options passed are merged to the hash.
    def subscription(options = {})
      sub = {:server => config[:server], :timestamp => (Time.now.to_f * 1000).round}.merge(options)
      sub[:signature] = Digest::SHA1.hexdigest([config[:secret_token], sub[:channel], sub[:timestamp]].join)
      sub
    end

    # Determine if the signature has expired given a timestamp.
    def signature_expired?(timestamp)
      timestamp < ((Time.now.to_f - config[:signature_expiration])*1000).round if config[:signature_expiration]
    end
    
    def log_status( msg )
      unless config[:log_state]
        puts msg
      else
        true
      end
    end

    # Returns the Faye Rack application.
    # Any options given are passed to the Faye::RackAdapter.
    def faye_app(options = {})
      options = {:mount => "/faye", :timeout => 45, :ping => 15, :extensions => [FayeExtension.new]}.merge(options)
      connection = Faye::RackAdapter.new(options)
      connection.on(:handshake) do |client_id|
        log_status "Client #{client_id} handshake!"
      end
      connection.on(:subscribe) do |client_id, channel|
        log_status "Client #{client_id} subscribes Channel: #{channel}!"
      end
      connection.on(:unsubscribe) do |client_id,channel|
        log_status "Client #{client_id} leaves Channel: #{channel}!"
      end
      connection.on(:publish) do |client_id, channel, data|
        log_status "#{client_id ? "Client #{client_id}": "Server"} publishes to Channel: #{channel}!"
      end
      connection.on(:disconnect) do |client_id|
        log_status "Client #{client_id} is disconnected!"
      end
      
      connection
    end
  end

  reset_config
end
