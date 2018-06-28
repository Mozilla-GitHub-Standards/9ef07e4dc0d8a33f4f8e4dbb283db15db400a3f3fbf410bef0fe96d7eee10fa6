require 'ssh_scan/scan_engine'
require 'ssh_scan_worker/version'
require 'openssl'
require 'net/https'

module SSHScan
  class Worker
    def initialize(opts = {})
      raise ArgumentError.new("API server not specified") unless ENV['sshscan.api.host'] || opts["server"]
      @server =  ENV['SSHSCAN_API_HOST'] || opts["server"]
      
      raise ArgumentError.new("API scheme not specified") unless ENV['sshscan.api.host'] || opts["scheme"]
      @scheme = ENV['SSHSCAN_API_SCHEME'] || opts["scheme"]

      raise ArgumentError.new("API verify not specified") unless ENV['sshscan.api.verify'] || opts["verify"]
      @verify = ENV['SSHSCAN_API_VERIFY'] || opts["verify"]

      raise ArgumentError.new("API port not specified") unless ENV['sshscan.api.port'] || opts["port"]
      @port = ENV['SSHSCAN_API_PORT'] || opts["port"]

      raise ArgumentError.new("API auth token not specified") unless ENV['sshscan.api.token'] || opts["token"]
      @auth_token = ENV['SSHSCAN_API_TOKEN'] || opts["token"] 

      @logger = setup_logger(opts["logger"])
      @poll_interval = opts["poll_interval"] || 5 # in seconds
      @poll_restore_interval = opts["poll_restore_interval"] || 5 # in seconds
      @worker_id = SecureRandom.uuid
    end

    def setup_logger(logger)
      case logger
      when Logger
        return logger
      when String
        return Logger.new(logger)
      end

      return Logger.new(STDOUT)
    end

    def run!
      loop do
        begin
          response = retrieve_work
          
          if response["work"]
            work = response["work"]
            results = perform_work(work)
            post_results(results, work)
          elsif response["error"]
            @logger.info("Error: #{response["error"]}")
            sleep @poll_interval
            next
          else
            @logger.info("No jobs available from #{@server}:#{@port} (waiting #{@poll_interval} seconds)")
            sleep @poll_interval
            next
          end
        rescue Errno::ECONNREFUSED => e
          @logger.error("Cannot reach API endpoint #{@server}:#{@port}, waiting #{@poll_restore_interval} seconds")
          sleep @poll_restore_interval
        #rescue RuntimeError => e
          @logger.error(e.inspect)
        end
      end
    end

    def retrieve_work
      (Net::HTTP::SSL_IVNAMES << :@ssl_options).uniq!
      (Net::HTTP::SSL_ATTRIBUTES << :options).uniq!

      Net::HTTP.class_eval do
        attr_accessor :ssl_options
      end

      uri = URI(
        "#{@scheme}://#{@server}:#{@port}/api/v1/\
work?worker_id=#{@worker_id}"
      )
      http = Net::HTTP.new(uri.host, uri.port)

      if @scheme == "https"
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE if @verify == false
        options_mask =
          OpenSSL::SSL::OP_NO_SSLv2 +
          OpenSSL::SSL::OP_NO_SSLv3 +
          OpenSSL::SSL::OP_NO_COMPRESSION
        http.ssl_options = options_mask
      end

      request = Net::HTTP::Get.new(uri.path)
      request.add_field("SSH_SCAN_AUTH_TOKEN", @auth_token) unless @auth_token.nil?
      response = http.request(request)
      JSON.parse(response.body)
    end

    def perform_work(work)
      @logger.info("Started job: #{work["uuid"]}")
      work["sockets"] = [work["target"] + ":" + work["port"].to_s]
      scan_engine = SSHScan::ScanEngine.new
      work["fingerprint_database"] = File.join(File.dirname(__FILE__),"../../data/fingerprints.yml")
      work["policy"] = File.join(File.dirname(__FILE__),"../../config/policies/mozilla_modern.yml")
      work["timeout"] = 5
      results = scan_engine.scan(work)
      @logger.info("Completed job: #{work["uuid"]}")
      return results
    end

    def post_results(results, job)
      uri = URI(
        "#{@scheme}://#{@server}:#{@port}/api/v1/\
work/results/#{@worker_id}/#{job["uuid"]}"
      )
      http = Net::HTTP.new(uri.host, uri.port)

      if @scheme == "https"
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE if @verify == false
        options_mask =
          OpenSSL::SSL::OP_NO_SSLv2 +
          OpenSSL::SSL::OP_NO_SSLv3 +
          OpenSSL::SSL::OP_NO_COMPRESSION
        http.ssl_options = options_mask
      end

      request = Net::HTTP::Post.new(uri.path)
      request.add_field("SSH_SCAN_AUTH_TOKEN", @auth_token) unless @auth_token.nil?
      request.add_field("Content-Type", "application/json")

      request.body = results.to_json
      http.request(request)
      @logger.info("Posted job: #{job["uuid"]}")
    end
  end
end