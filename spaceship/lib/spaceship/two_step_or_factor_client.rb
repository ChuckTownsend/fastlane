require_relative 'globals'
require_relative 'tunes/tunes_client'
require_relative 'tunes/recovery_device'

module Spaceship
  class Client
    def handle_two_step_or_factor(response)
      # extract `x-apple-id-session-id` and `scnt` from response, to be used by `update_request_headers`
      @x_apple_id_session_id = response["x-apple-id-session-id"]
      @scnt = response["scnt"]

      puts("")
      puts("Two-step Verification (4 digits code) or Two-factor Authentication (6 digits code) is enabled for account '#{self.user}'")
      puts("More information about Two-step Verification (4 digits code): https://support.apple.com/en-us/HT204152")
      puts("More information about Two-factor Authentication (6 digits code): https://support.apple.com/en-us/HT204915")
      puts("")

      # get authentication options
      r = request(:get) do |req|
        req.url("https://idmsa.apple.com/appleauth/auth")
        update_request_headers(req)
      end

      if r.body.kind_of?(Hash) && r.body["trustedDevices"].kind_of?(Array)
        handle_two_step(r)
      elsif r.body.kind_of?(Hash) && r.body["trustedPhoneNumbers"].kind_of?(Array) && r.body["trustedPhoneNumbers"].first.kind_of?(Hash)
        handle_two_factor(r)
      else
        raise "Although response from Apple indicated activated Two-step Verification or Two-factor Authentication, spaceship didn't know how to handle this response: #{r.body}"
      end
    end

    def handle_two_step(r)
      if r.body.fetch("securityCode", {})["tooManyCodesLock"].to_s.length > 0
        raise Tunes::Error.new, "Too many verification codes have been sent. Enter the last code you received, use one of your devices, or try again later."
      end

      # turn `trustedDevices` into handy array of objects
      old_client = (begin
                      Tunes::RecoveryDevice.client
                    rescue
                      nil # since client might be nil, which raises an exception
                    end)
      Tunes::RecoveryDevice.client = self # temporary set it as it's required by the factory method
      devices = r.body["trustedDevices"].collect do |current|
        Tunes::RecoveryDevice.factory(current)
      end
      Tunes::RecoveryDevice.client = old_client

      puts("Two-step Verification (4 digits code) is enabled for account '#{self.user}'")
      puts("Please select a trusted device to verify your identity")
      available = devices.collect do |c|
        "#{c.name}\t#{c.model_name || 'SMS'}\t(#{c.device_id})"
      end
      result = choose(*available)
      device_id = result.match(/.*\t.*\t\((.*)\)/)[1]
      handle_two_step_for_device(r, device_id)
    end

    # this is extracted into its own method so it can be called multiple times (see end)
    def handle_two_step_for_device(r, device_id)
      # Request token to device
      r = request(:put) do |req|
        req.url("https://idmsa.apple.com/appleauth/auth/verify/device/#{device_id}/securitycode")
        update_request_headers(req)
      end

      # we use `Spaceship::TunesClient.new.handle_itc_response`
      # since this might be from the Dev Portal, but for 2 step
      Spaceship::TunesClient.new.handle_itc_response(r.body)

      puts("Successfully requested notification")
      code = ask("Please enter the 4 digit code: ")
      puts("Requesting session...")

      # Send token to server to get a valid session
      r = request(:post) do |req|
        req.url("https://idmsa.apple.com/appleauth/auth/verify/device/#{device_id}/securitycode")
        req.headers['Content-Type'] = 'application/json'
        req.body = { "code" => code.to_s }.to_json
        update_request_headers(req)
      end

      begin
        Spaceship::TunesClient.new.handle_itc_response(r.body) # this will fail if the code is invalid
      rescue => ex
        # If the code was entered wrong
        # {
        #   "securityCode": {
        #     "code": "1234"
        #   },
        #   "securityCodeLocked": false,
        #   "recoveryKeyLocked": false,
        #   "recoveryKeySupported": true,
        #   "manageTrustedDevicesLinkName": "appleid.apple.com",
        #   "suppressResend": false,
        #   "authType": "hsa",
        #   "accountLocked": false,
        #   "validationErrors": [{
        #     "code": "-21669",
        #     "title": "Incorrect Verification Code",
        #     "message": "Incorrect verification code."
        #   }]
        # }
        if ex.to_s.include?("verification code") # to have a nicer output
          puts("Error: Incorrect verification code")
          return handle_two_step_for_device(r, device_id)
        end

        raise ex
      end

      store_session

      return true
    end

    def handle_two_factor(response, depth = 0)
      if depth == 0
        puts("Two-factor Authentication (6 digits code) is enabled for account '#{self.user}'")

        two_factor_url = "https://github.com/fastlane/fastlane/tree/master/spaceship#2-step-verification"
        puts("If you're running this in a non-interactive session (e.g. server or CI)")
        puts("check out #{two_factor_url}")
      end

      # "verification code" has already be pushed to devices

      security_code = response.body["securityCode"]
      # "securityCode": {
      # 	"length": 6,
      # 	"tooManyCodesSent": false,
      # 	"tooManyCodesValidated": false,
      # 	"securityCodeLocked": false
      # },
      code_length = security_code["length"]
      puts("")
      puts("(Input `sms` to escape this prompt and select a trusted phone number to send the code as a text message)")
      code = ask("Please enter the #{code_length} digit code:")
      if(code == 'sms')
        code = request_two_factor_code_from_phone(response.body["trustedPhoneNumbers"], code_length)
      end
      puts("Requesting session...")

      # Send "verification code" back to server to get a valid session
      r = request(:post) do |req|
        req.url("https://idmsa.apple.com/appleauth/auth/verify/trusteddevice/securitycode")
        req.headers['Content-Type'] = 'application/json'
        req.body = { "securityCode" => { "code" => code.to_s } }.to_json
        update_request_headers(req)
      end

      begin
        puts r.body
        # we use `Spaceship::TunesClient.new.handle_itc_response`
        # since this might be from the Dev Portal, but for 2 factor
        Spaceship::TunesClient.new.handle_itc_response(r.body) # this will fail if the code is invalid
      rescue => ex
        # If the code was entered wrong
        # {
        #   "service_errors": [{
        #     "code": "-21669",
        #     "title": "Incorrect Verification Code",
        #     "message": "Incorrect verification code."
        #   }],
        #   "hasError": true
        # }

        if ex.to_s.include?("verification code") # to have a nicer output
          puts("Error: Incorrect verification code")
          depth = depth+1 # TODO check if works
          return handle_two_factor(response, depth)
        end

        raise ex
      end

      store_session

      return true
    end

    def get_id_for_number(trustedPhoneNumbers, result)
      trustedPhoneNumbers.each do |phone|
        phone_id = phone['id']
        return phone_id if phone['numberWithDialCode'] == result 
      end     
    end

    def request_two_factor_code_from_phone(trustedPhoneNumbers, code_length)
      puts("Please select a trusted phone number to send code to:")

      available = trustedPhoneNumbers.collect do |current|
        current['numberWithDialCode']
      end
      result = choose(*available)

      phone_id = get_id_for_number(trustedPhoneNumbers, result)

      # Request code
      r = request(:put) do |req|
        req.url("https://idmsa.apple.com/appleauth/auth/verify/phone")
        req.headers['Content-Type'] = 'application/json'
        req.body = { "phoneNumber" => { "id" => phone_id }, "mode" => "sms" }.to_json
        update_request_headers(req)
      end

      # we use `Spaceship::TunesClient.new.handle_itc_response`
      # since this might be from the Dev Portal, but for 2 step
      Spaceship::TunesClient.new.handle_itc_response(r.body)

      puts("Successfully requested text message")

      ask("Please enter the #{code_length} digit code you received at #{result}:")
    end

    def store_session
      # If the request was successful, r.body is actually nil
      # The previous request will fail if the user isn't on a team
      # on App Store Connect, but it still works, so we're good

      # Tell iTC that we are trustworthy (obviously)
      # This will update our local cookies to something new
      # They probably have a longer time to live than the other poor cookies
      # Changed Keys
      # - myacinfo
      # - DES5c148586dfd451e55afb0175f62418f91
      # We actually only care about the DES value

      request(:get) do |req|
        req.url("https://idmsa.apple.com/appleauth/auth/2sv/trust")
        update_request_headers(req)
      end
      # This request will fail if the user isn't added to a team on iTC
      # However we don't really care, this request will still return the
      # correct DES... cookie

      self.store_cookie
    end

    # Responsible for setting all required header attributes for the requests
    # to succeed
    def update_request_headers(req)
      req.headers["X-Apple-Id-Session-Id"] = @x_apple_id_session_id
      req.headers["X-Apple-Widget-Key"] = self.itc_service_key
      req.headers["Accept"] = "application/json"
      req.headers["scnt"] = @scnt
    end
  end
end
