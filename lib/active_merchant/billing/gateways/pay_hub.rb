module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class PayHubGateway < Gateway
      self.live_url = 'https://api.payhub.com/api/v2'
      self.test_url = 'https://api.payhub.com/api/v2'

      self.supported_countries = ['US']
      self.default_currency = 'USD'
      self.supported_cardtypes = [:visa, :master, :american_express, :discover]

      self.homepage_url = 'http://www.payhub.com/'
      self.display_name = 'PayHub'

      CVV_CODE_TRANSLATOR = {
          'M' => 'CVV matches',
          'N' => 'CVV does not match',
          'P' => 'CVV not processed',
          'S' => 'CVV should have been present',
          'U' => 'CVV request unable to be processed by issuer'
      }

      AVS_CODE_TRANSLATOR = {
          '0' => "Approved, Address verification was not requested.",
          'A' => "Approved, Address matches only.",
          'B' => "Address Match. Street Address math for international transaction Postal Code not verified because of incompatible formats (Acquirer sent both street address and Postal Code)",
          'C' => "Serv Unavailable. Street address and Postal Code not verified for international transaction because of incompatible formats (Acquirer sent both street and Postal Code).",
          'D' => "Exact Match, Street Address and Postal Code match for international transaction.",
          'F' => "Exact Match, Street Address and Postal Code match. Applies to UK only.",
          'G' => "Ver Unavailable, Non-U.S. Issuer does not participate.",
          'I' => "Ver Unavailable, Address information not verified for international transaction",
          'M' => "Exact Match, Street Address and Postal Code match for international transaction",
          'N' => "No - Address and ZIP Code does not match",
          'P' => "Zip Match, Postal Codes match for international transaction Street address not verified because of incompatible formats (Acquirer sent both street address and Postal Code).",
          'R' => "Retry - Issuer system unavailable",
          'S' => "Serv Unavailable, Service not supported",
          'U' => "Ver Unavailable, Address unavailable.",
          'W' => "ZIP match - Nine character numeric ZIP match only.",
          'X' => "Exact match, Address and nine-character ZIP match.",
          'Y' => "Exact Match, Address and five character ZIP match.",
          'Z' => "Zip Match, Five character numeric ZIP match only.",
          '1' => "Cardholder name and ZIP match AMEX only.",
          '2' => "Cardholder name, address, and ZIP match AMEX only.",
          '3' => "Cardholder name and address match AMEX only.",
          '4' => "Cardholder name match AMEX only.",
          '5' => "Cardholder name incorrect, ZIP match AMEX only.",
          '6' => "Cardholder name incorrect, address and ZIP match AMEX only.",
          '7' => "Cardholder name incorrect, address match AMEX only.",
          '8' => "Cardholder, all do not match AMEX only."
      }

      STANDARD_ERROR_CODE_MAPPING = {
          '14' => STANDARD_ERROR_CODE[:invalid_number],
          '80' => STANDARD_ERROR_CODE[:invalid_expiry_date],
          '82' => STANDARD_ERROR_CODE[:invalid_cvc],
          '54' => STANDARD_ERROR_CODE[:expired_card],
          '51' => STANDARD_ERROR_CODE[:card_declined],
          '05' => STANDARD_ERROR_CODE[:card_declined],
          '61' => STANDARD_ERROR_CODE[:card_declined],
          '62' => STANDARD_ERROR_CODE[:card_declined],
          '65' => STANDARD_ERROR_CODE[:card_declined],
          '93' => STANDARD_ERROR_CODE[:card_declined],
          '01' => STANDARD_ERROR_CODE[:call_issuer],
          '02' => STANDARD_ERROR_CODE[:call_issuer],
          '04' => STANDARD_ERROR_CODE[:pickup_card],
          '07' => STANDARD_ERROR_CODE[:pickup_card],
          '41' => STANDARD_ERROR_CODE[:pickup_card],
          '43' => STANDARD_ERROR_CODE[:pickup_card]
      }

      def initialize(options={})
        requires!(options, :orgid, :username, :password, :tid)

        super
      end

      def authorize(amount, creditcard, options = {})
        post = setup_post
        add_card_data(post, creditcard, (options[:address] || options[:billing_address]))
        add_bill(post, amount)
        add_customer_data(post, options)

        commit(post, 'authOnly')
      end

      def purchase(amount, creditcard, options={})
        post = setup_post
        add_card_data(post, creditcard, (options[:address] || options[:billing_address]))
        add_bill(post, amount)
        add_customer_data(post, options)

        commit(post, 'sale')
      end

      def refund(amount, trans_id, options={})
        # Attempt a void in case the transaction is unsettled
        response = void(trans_id)
        return response if response.success?

        post = setup_post
        add_reference(post, trans_id)
        commit(post, 'refund')
      end

      def void(trans_id, _options={})
        post = setup_post
        add_reference(post, trans_id)
        commit(post, 'void')
      end

      def capture(amount, trans_id, options = {})
        post = setup_post

        post[:transaction_id] = trans_id
        add_bill(post, amount)

        commit(post, 'capture')
      end

      # No void, as PayHub's void does not work on authorizations

      def verify(creditcard, options={})
        post = setup_post
        add_card_data(post, creditcard, (options[:address] || options[:billing_address]))
        add_customer_data(post, options)

        commit(post, 'verify')
      end

      private

      def setup_post
        post = {
            merchant: {

                organization_id: @options[:orgid],
                terminal_id: @options[:tid]
            }
        }
        post[:mode] = 'demo' if test?
        post
      end

      def add_reference(post, trans_id)
        post[:transaction_id] = trans_id
      end

      def add_customer_data(post, options = {})
        customer_data = {
            first_name: options[:first_name],
            last_name: options[:last_name],
            phone_number: options[:phone],
            email_address: options[:email]
        }
        post[:customer] = customer_data
      end

      def add_bill(post, base_amount, tax_amount=nil, shipping_amount=nil, invoice_number=nil)
        bill = {base_amount: amount(base_amount)}
        bill[:tax_amount] = amount(tax_amount) if tax_amount
        bill[:shipping_amount] = amount(shipping_amount) if shipping_amount
        bill[:invoice_number] = invoice_number if invoice_number
        post[:bill] = bill
      end

      def add_card_data(post, creditcard, address=nil)
        card_data = {
            card_number: creditcard.number,
            card_expiry_date: "#{creditcard.year}/#{creditcard.month}", #The card expiry date in the YYYYMM format.
            cvv_data: creditcard.verification_value,
            cvv_code: 'Y'
        }
        add_address(card_data, address)
        post[:card_data] = card_data
        post[:record_format] = 'CC'
      end

      def add_address(card_data, address)
        return unless address
        card_data[:billing_address_1] = address[:address1]
        card_data[:billing_address_2] = address[:address2]
        card_data[:billing_zip] = address[:zip]
        card_data[:billing_state] = address[:state]
        card_data[:billing_city] = address[:city]
      end

      def parse(body)
        JSON.parse(body)
      end

      def request_headers
        {
            'Content-Type' => 'application/json',
            'Authorization' => "Bearer #{@options[:password]}",
            'Accept' => 'application/json',
            'cache-control' => 'no-cache'
        }
      end

      def url_for_action(action)
        if test?
          "#{test_url}/#{action}"
        else
          "#{live_url}/#{action}"
        end
      end

      def commit(post, action)
        success = false

        begin
          raw_response = ssl_post(url_for_action(action), post.to_json, request_headers)
          response = parse(raw_response)
          success = true
        rescue ResponseError => e
          raw_response = e.response.body
          response = response_error(raw_response)
        rescue JSON::ParserError
          response = json_error(raw_response)
        end

        Response.new(success,
                     response_message(response),
                     response,
                     test: test?,
                     avs_result: {code: response['AVS_RESULT_CODE']},
                     cvv_result: response['VERIFICATION_RESULT_CODE'],
                     error_code: (success ? nil : STANDARD_ERROR_CODE_MAPPING[response['RESPONSE_CODE']]),
                     authorization: response['TRANSACTION_ID']
        )
      end

      def response_error(raw_response)
        parse(raw_response)
      rescue JSON::ParserError
        json_error(raw_response)
      end

      def json_error(raw_response)
        {
            error_message: "Invalid response received from the Payhub API.  Please contact wecare@payhub.com if you continue to receive this message." +
                "  (The raw response returned by the API was #{raw_response.inspect})"
        }
      end

      def response_message(response)
        (response['RESPONSE_TEXT'] || response["RESPONSE_CODE"] || response[:error_message])
      end
    end
  end
end
