@IsTest
private class StripeConfigReaderTest {

    /*
     * Flexible mock used specifically for StripeConfigReader webhook tests.
     */
    private class ConfigReaderMock implements HttpCalloutMock {
        private String scenario;

        ConfigReaderMock(String scenario) {
            this.scenario = scenario;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse response = new HttpResponse();
            response.setHeader('Content-Type', 'application/json');

            String endpoint = req.getEndpoint();
            String method = req.getMethod();

            /*
             * GET /v1/account
             */
            if (endpoint.contains('/v1/account')) {
                if (scenario == 'ACCOUNT_ERROR') {
                    response.setStatusCode(401);
                    response.setBody(
                        '{"error":{"message":"Invalid API key"}}'
                    );
                } else {
                    response.setStatusCode(200);
                    response.setBody(
                        '{' +
                            '"id":"acct_test_123",' +
                            '"country":"IN",' +
                            '"default_currency":"inr"' +
                        '}'
                    );
                }

                return response;
            }

            /*
             * GET /v1/webhook_endpoints
             */
            if (
                endpoint.contains('/v1/webhook_endpoints') &&
                method == 'GET'
            ) {
                response.setStatusCode(200);

                if (scenario == 'ENDPOINT_LIST_ERROR') {
                    response.setStatusCode(500);
                    response.setBody(
                        '{"error":{"message":"Unable to retrieve endpoints"}}'
                    );
                } else if (scenario == 'NOT_REGISTERED') {
                    response.setBody(
                        '{"object":"list","data":[]}'
                    );
                } else if (scenario == 'DISABLED') {
                    response.setBody(
                        '{' +
                            '"object":"list",' +
                            '"data":[' +
                                '{' +
                                    '"id":"we_disabled",' +
                                    '"url":"https://demo.my.site.com/services/apexrest/acxitech/stripe/webhook/",' +
                                    '"status":"disabled",' +
                                    '"enabled_events":["customer.created"]' +
                                '}' +
                            ']' +
                        '}'
                    );
                } else if (scenario == 'EVENT_NOT_ENABLED') {
                    response.setBody(
                        '{' +
                            '"object":"list",' +
                            '"data":[' +
                                '{' +
                                    '"id":"we_no_event",' +
                                    '"url":"https://demo.my.site.com/services/apexrest/acxitech/stripe/webhook",' +
                                    '"status":"enabled",' +
                                    '"enabled_events":["checkout.session.completed"]' +
                                '}' +
                            ']' +
                        '}'
                    );
                } else {
                    response.setBody(
                        '{' +
                            '"object":"list",' +
                            '"data":[' +
                                '{' +
                                    '"id":"we_connected",' +
                                    '"url":"https://demo.my.site.com/services/apexrest/acxitech/stripe/webhook",' +
                                    '"status":"enabled",' +
                                    '"enabled_events":["customer.created","checkout.session.completed"]' +
                                '}' +
                            ']' +
                        '}'
                    );
                }

                return response;
            }

            /*
             * POST /v1/customers
             */
            if (
                endpoint.contains('/v1/customers') &&
                method == 'POST'
            ) {
                if (scenario == 'CUSTOMER_CREATE_ERROR') {
                    response.setStatusCode(400);
                    response.setBody(
                        '{"error":{"message":"Customer creation failed"}}'
                    );
                } else {
                    response.setStatusCode(200);
                    response.setBody(
                        '{' +
                            '"id":"cus_webhook_test",' +
                            '"object":"customer",' +
                            '"name":"Salesforce Webhook Health Check"' +
                        '}'
                    );
                }

                return response;
            }

            /*
             * DELETE /v1/customers/{id}
             */
            if (
                endpoint.contains('/v1/customers/') &&
                method == 'DELETE'
            ) {
                response.setStatusCode(200);
                response.setBody(
                    '{"id":"cus_webhook_test","deleted":true}'
                );

                return response;
            }

            /*
             * DELETE existing webhook endpoint
             */
            if (
                endpoint.contains('/v1/webhook_endpoints/') &&
                method == 'DELETE'
            ) {
                response.setStatusCode(200);
                response.setBody(
                    '{"id":"we_old","deleted":true}'
                );

                return response;
            }

            /*
             * POST /v1/webhook_endpoints
             */
            if (
                endpoint.contains('/v1/webhook_endpoints') &&
                method == 'POST'
            ) {
                if (scenario == 'REGISTER_ERROR') {
                    response.setStatusCode(400);
                    response.setBody(
                        '{"error":{"message":"Registration failed"}}'
                    );
                } else {
                    response.setStatusCode(200);
                    response.setBody(
                        '{' +
                            '"id":"we_registered",' +
                            '"object":"webhook_endpoint",' +
                            '"secret":"whsec_test_registered",' +
                            '"status":"enabled"' +
                        '}'
                    );
                }

                return response;
            }

            response.setStatusCode(200);
            response.setBody('{}');
            return response;
        }
    }

    private static Map<String, Object> parse(String jsonValue) {
        return (Map<String, Object>) JSON.deserializeUntyped(jsonValue);
    }

    private static Stripe_Credentials__c createCredentials() {
        Stripe_Credentials__c credentials =
            Stripe_Credentials__c.getOrgDefaults();

        if (credentials == null || credentials.Id == null) {
            credentials = new Stripe_Credentials__c(
                SetupOwnerId = UserInfo.getOrganizationId()
            );
        }

        credentials.Environment__c = 'test';
        credentials.Auth_Mode__c = 'KEY';
        credentials.Publishable_Key_Test__c = 'pk_test_123';
        credentials.Secret_Key_Test__c = 'sk_test_123';
        credentials.Webhook_Signing_Secret_Test__c = 'whsec_test_123';
        credentials.Default_Currency__c = 'usd';
        credentials.Hosted_Enabled__c = true;
        credentials.Embedded_Enabled__c = false;
        credentials.Webhook_Base_Url__c =
            'https://demo.my.site.com';

        upsert credentials;
        return credentials;
    }

    private static Stripe_Payment_Config__c createPaymentConfig(
        String configName,
        String sourceObject,
        Boolean active
    ) {
        Stripe_Payment_Config__c config =
            new Stripe_Payment_Config__c(
                Name = configName,
                Source_Object__c = sourceObject,
                Checkout_Mode__c = 'HOSTED',
                Payment_Type__c = 'One-Time',
                Amount_Field__c =
                    'HARDCODED|99.99|true|true|false|Amount|1|true',
                Name_Field__c =
                    'FIELD|Name|true|false|false|Name|2|true',
                Email_Field__c =
                    'BLANK||true|false|false|Email|3|false',
                Product_Info_Field__c =
                    'HARDCODED|Order {RecordId}|true|false|false|Product|4|true',
                Currency__c = 'usd',
                Is_Active__c = active,
                Send_Notification__c = true
            );

        insert config;
        return config;
    }

    private static String createWebhookPayload(String token) {
        return JSON.serialize(
            new Map<String, Object>{
                'id' => 'evt_health_check',
                'type' => 'customer.created',
                'data' => new Map<String, Object>{
                    'object' => new Map<String, Object>{
                        'id' => 'cus_webhook_test',
                        'metadata' => new Map<String, Object>{
                            'salesforce_webhook_test' => 'true',
                            'salesforce_webhook_test_token' => token
                        }
                    }
                }
            }
        );
    }

    @IsTest
    static void credentials_saveAndInfo_noSecretExposed() {
        Test.startTest();

        String saveResult = StripeConfigReader.saveCredentials(
            JSON.serialize(
                new Map<String, Object>{
                    'environment' => 'test',
                    'publishableKeyTest' => 'pk_test_abc',
                    'secretKeyTest' => 'sk_test_supersecretvalue',
                    'webhookSecretTest' => 'whsec_a, whsec_b',
                    'hostedEnabled' => true,
                    'embeddedEnabled' => true,
                    'customElementEnabled' => true,
                    'linkEnabled' => true,
                    'customerPortalEnabled' => true,
                    'defaultCurrency' => 'USD',
                    'defaultProductInfo' => 'Test product',
                    'hostedRedirect' => 'same',
                    'successUrl' => 'https://example.com/success',
                    'cancelUrl' => 'https://example.com/cancel',
                    'returnUrl' => 'https://example.com/return',
                    'logoUrl' => 'https://example.com/logo.png',
                    'apiVersion' => '2024-06-20',
                    'apiTimeoutSec' => 45,
                    'webhookBaseUrl' =>
                        'https://demo.my.site.com'
                }
            )
        );

        Test.stopTest();

        Map<String, Object> saveResponse = parse(saveResult);
        System.assertEquals(true, saveResponse.get('success'));

        String infoJson = StripeConfigReader.getCredentialsInfo();
        Map<String, Object> info = parse(infoJson);

        System.assertEquals(true, info.get('isConfigured'));
        System.assertEquals(
            'pk_test_abc',
            info.get('publishableKey')
        );
        System.assertEquals(true, info.get('secretKeySet'));
        System.assertEquals(true, info.get('webhookSecretSet'));
        System.assertEquals(true, info.get('hostedEnabled'));
        System.assertEquals(true, info.get('embeddedEnabled'));
        System.assertEquals(true, info.get('linkEnabled'));
        System.assertEquals('usd', info.get('defaultCurrency'));
        System.assertEquals(
            'https://demo.my.site.com',
            info.get('webhookBaseUrl')
        );

        System.assert(
            !infoJson.contains('supersecretvalue'),
            'The raw secret key must never be exposed to clients.'
        );

        System.assert(
            String.valueOf(info.get('secretKeyMasked')).contains('…'),
            'The secret should be masked.'
        );

        List<String> secrets =
            StripeConfigReader.getWebhookSecrets();

        System.assertEquals(
            2,
            secrets.size(),
            'Two rotation secrets should be parsed.'
        );
        System.assertEquals('whsec_a', secrets[0]);
        System.assertEquals('whsec_b', secrets[1]);
    }

    @IsTest
    static void credentials_liveEnvironmentResolved() {
        Stripe_Credentials__c credentials =
            new Stripe_Credentials__c(
                SetupOwnerId = UserInfo.getOrganizationId(),
                Environment__c = 'LIVE',
                Auth_Mode__c = 'KEY',
                Publishable_Key_Test__c = 'pk_test_ignore',
                Secret_Key_Test__c = 'sk_test_ignore',
                Publishable_Key_Live__c = 'pk_live_123',
                Secret_Key_Live__c = 'sk_live_123',
                Webhook_Signing_Secret_Live__c =
                    'whsec_live_a\nwhsec_live_b',
                Default_Currency__c = 'INR'
            );

        insert credentials;

        StripeConfigReader.Credentials result =
            StripeConfigReader.getCredentials();

        System.assertEquals('live', result.environment);
        System.assertEquals('pk_live_123', result.publishableKey);
        System.assertEquals('sk_live_123', result.secretKey);
        System.assertEquals('inr', result.defaultCurrency);
        System.assertEquals(
            StripeConfigReader.DEFAULT_API_VERSION,
            result.apiVersion
        );
        System.assertEquals(2, result.webhookSecrets.size());
        System.assertEquals(30000, result.apiTimeoutMs);
        System.assertEquals(0, result.retryCount);
    }

    @IsTest
    static void credentials_namedCredentialAppliedToLiveEnvironment() {
        Test.startTest();

        String responseJson =
            StripeConfigReader.saveCredentials(
                JSON.serialize(
                    new Map<String, Object>{
                        'environment' => 'live',
                        'authMode' => 'NAMED_CREDENTIAL',
                        'namedCredential' => 'Stripe_Live',
                        'publishableKeyLive' => 'pk_live_named'
                    }
                )
            );

        Test.stopTest();

        System.assertEquals(
            true,
            parse(responseJson).get('success')
        );

        StripeConfigReader.Credentials credentials =
            StripeConfigReader.getCredentials();

        System.assertEquals('live', credentials.environment);
        System.assertEquals(
            'NAMED_CREDENTIAL',
            credentials.authMode
        );
        System.assertEquals(
            'Stripe_Live',
            credentials.namedCredential
        );
    }

    @IsTest
    static void credentials_emptyStateAndInvalidJson() {
        System.assertEquals(
            0,
            StripeConfigReader.getWebhookSecrets().size()
        );

        Map<String, Object> info =
            parse(StripeConfigReader.getCredentialsInfo());

        System.assertEquals(false, info.get('isConfigured'));
        System.assertEquals('test', info.get('environment'));
        System.assertEquals(false, info.get('secretKeySet'));
        System.assertEquals(
            StripeConfigReader.DEFAULT_API_VERSION,
            info.get('apiVersion')
        );

        Map<String, Object> invalid =
            parse(
                StripeConfigReader.saveCredentials(
                    '{invalid-json'
                )
            );

        System.assertEquals(false, invalid.get('success'));
        System.assertNotEquals(null, invalid.get('message'));
    }

    @IsTest
    static void testConnection_ok() {
        createCredentials();

        Test.setMock(
            HttpCalloutMock.class,
            new ConfigReaderMock('ACCOUNT_OK')
        );

        Test.startTest();
        String responseJson =
            StripeConfigReader.testConnection();
        Test.stopTest();

        Map<String, Object> response = parse(responseJson);

        System.assertEquals(true, response.get('success'));
        System.assertEquals(
            'Connected to Stripe.',
            response.get('message')
        );
        System.assertEquals(
            'acct_test_123',
            response.get('accountId')
        );
        System.assertEquals('IN', response.get('country'));
        System.assertEquals(
            'inr',
            response.get('defaultCurrency')
        );
    }

    @IsTest
    static void testConnection_error() {
        createCredentials();

        Test.setMock(
            HttpCalloutMock.class,
            new ConfigReaderMock('ACCOUNT_ERROR')
        );

        Test.startTest();
        String responseJson =
            StripeConfigReader.testConnection();
        Test.stopTest();

        Map<String, Object> response = parse(responseJson);

        System.assertEquals(false, response.get('success'));
        System.assert(
            String.valueOf(response.get('message'))
                .contains('Invalid API key')
        );
    }

    @IsTest
    static void registerWebhook_savesSecret() {
        Stripe_Credentials__c credentials =
            createCredentials();

        credentials.Webhook_Base_Url__c =
            'https://demo.my.site.com';
        update credentials;

        Test.setMock(
            HttpCalloutMock.class,
            new ConfigReaderMock('REGISTER_OK')
        );

        Test.startTest();

        String responseJson =
            StripeConfigReader.registerWebhook(
                'https://demo.my.site.com/services/apexrest/acxitech/stripe/webhook'
            );

        Test.stopTest();

        Map<String, Object> response = parse(responseJson);

        System.assertEquals(true, response.get('success'));
        System.assertEquals(
            'we_registered',
            response.get('endpointId')
        );

        List<String> secrets =
            StripeConfigReader.getWebhookSecrets();

        System.assertEquals(1, secrets.size());
        System.assertEquals(
            'whsec_test_registered',
            secrets[0],
            'The signing secret returned by Stripe should be saved.'
        );
    }

    @IsTest
    static void registerWebhook_rejectsLoginDomain() {
        createCredentials();

        Test.startTest();

        String responseJson =
            StripeConfigReader.registerWebhook(
                'https://example.my.salesforce.com/services/apexrest/acxitech/stripe/webhook'
            );

        Test.stopTest();

        Map<String, Object> response = parse(responseJson);

        System.assertEquals(false, response.get('success'));
        System.assert(
            String.valueOf(response.get('message'))
                .contains('not publicly reachable')
        );
    }

    @IsTest
    static void registerWebhook_requiresCredentials() {
        Map<String, Object> response =
            parse(
                StripeConfigReader.registerWebhook(
                    'https://demo.my.site.com/services/apexrest/acxitech/stripe/webhook'
                )
            );

        System.assertEquals(false, response.get('success'));
        System.assert(
            String.valueOf(response.get('message'))
                .contains('secret key')
        );
    }

    @IsTest
    static void registerWebhook_handlesStripeFailure() {
        createCredentials();

        Test.setMock(
            HttpCalloutMock.class,
            new ConfigReaderMock('REGISTER_ERROR')
        );

        Test.startTest();

        Map<String, Object> response =
            parse(
                StripeConfigReader.registerWebhook(
                    'https://demo.my.site.com/services/apexrest/acxitech/stripe/webhook'
                )
            );

        Test.stopTest();

        System.assertEquals(false, response.get('success'));
        System.assert(
            String.valueOf(response.get('message'))
                .contains('Registration failed')
        );
    }

    @IsTest
    static void getCredentials_resolvesEnvironment() {
        createCredentials();

        StripeConfigReader.Credentials credentials =
            StripeConfigReader.getCredentials();

        System.assertEquals('test', credentials.environment);
        System.assertEquals(
            'sk_test_123',
            credentials.secretKey
        );
        System.assertEquals(
            'pk_test_123',
            credentials.publishableKey
        );
        System.assertEquals(
            1,
            credentials.webhookSecrets.size()
        );
    }

    @IsTest
    static void config_crud() {
        Test.startTest();

        String saveJson =
            StripeConfigReader.saveConfig(
                JSON.serialize(
                    new Map<String, Object>{
                        'Name' => 'OppPay',
                        'Source_Object' => 'Opportunity',
                        'Checkout_Mode' => 'HOSTED',
                        'Payment_Type' => 'One-Time',
                        'Amount_Field' =>
                            'FIELD|Amount|true|false|false|Amt|1|true',
                        'Name_Field' =>
                            'FIELD|Name|true|false|false|Name|2|true',
                        'Email_Field' =>
                            'FIELD|Account.PersonEmail|true|false|false|Email|3|true',
                        'Phone_Field' =>
                            'FIELD|Account.Phone|true|false|false|Phone|4|true',
                        'Product_Info' =>
                            'HARDCODED|Opportunity payment|true|false|false|Product|5|true',
                        'UDF1' =>
                            'HARDCODED|Value 1|true|false|false|UDF1|6|true',
                        'UDF10' =>
                            'HARDCODED|Value 10|true|false|false|UDF10|15|true',
                        'Price_Id' => 'price_123',
                        'Price_Id_Field' => 'Price_Id__c',
                        'Allowed_Payment_Methods' =>
                            'card,link',
                        'Currency' => 'usd',
                        'Post_Success' => 'StageName',
                        'Post_Value' => 'Closed Won',
                        'Post_Flow' => 'Payment_Success',
                        'QuickActionName' =>
                            'Stripe_Payment',
                        'Payment_Options_Config' =>
                            '{"allowPartial":true}',
                        'ValidationRuleConfig' =>
                            '{"required":["Amount"]}',
                        'Trial_Days' => 14,
                        'Allow_Promotion_Codes' => true,
                        'Collect_Billing_Address' => true,
                        'Save_Payment_Method' => true,
                        'Guest_Enabled' => true,
                        'Notification' => false,
                        'Is_Active' => true,
                        'Expiry_Hours' => 48
                    }
                )
            );

        Test.stopTest();

        System.assertEquals(
            true,
            parse(saveJson).get('success')
        );

        Map<String, Object> byName =
            parse(
                StripeConfigReader.getConfigByName(
                    'OppPay'
                )
            );

        System.assertEquals(true, byName.get('success'));

        String allConfigs =
            StripeConfigReader.getAllConfigs();

        System.assert(allConfigs.contains('OppPay'));
        System.assert(allConfigs.contains('price_123'));
        System.assert(allConfigs.contains('Value 10'));

        StripeConfigReader.PaymentConfig paymentConfig =
            StripeConfigReader.getConfig(
                'OppPay',
                'Opportunity'
            );

        System.assertNotEquals(null, paymentConfig);
        System.assertEquals(
            'HOSTED',
            paymentConfig.checkoutMode
        );
        System.assertEquals(
            'One-Time',
            paymentConfig.paymentType
        );
        System.assertEquals(
            'price_123',
            paymentConfig.priceId
        );
        System.assertEquals(14, paymentConfig.trialDays);
        System.assertEquals(
            true,
            paymentConfig.allowPromotionCodes
        );
        System.assertEquals(
            true,
            paymentConfig.collectBillingAddress
        );
        System.assertEquals(
            true,
            paymentConfig.savePaymentMethod
        );
        System.assertEquals(
            true,
            paymentConfig.guestEnabled
        );
        System.assertEquals(
            'card,link',
            paymentConfig.allowedPaymentMethods
        );
        System.assertEquals(
            10,
            paymentConfig.udfFields.size()
        );

        Map<String, Object> deleteResponse =
            parse(
                StripeConfigReader.deleteConfig(
                    'OppPay'
                )
            );

        System.assertEquals(
            true,
            deleteResponse.get('success')
        );
    }

    @IsTest
    static void config_validationAndMissingRecords() {
        Map<String, Object> blankName =
            parse(
                StripeConfigReader.saveConfig(
                    JSON.serialize(
                        new Map<String, Object>{
                            'Name' => '',
                            'Source_Object' => 'Account'
                        }
                    )
                )
            );

        System.assertEquals(
            false,
            blankName.get('success')
        );
        System.assert(
            String.valueOf(blankName.get('message'))
                .contains('Config name is required')
        );

        Map<String, Object> invalidJson =
            parse(
                StripeConfigReader.saveConfig(
                    '{invalid'
                )
            );

        System.assertEquals(
            false,
            invalidJson.get('success')
        );

        Map<String, Object> missingConfig =
            parse(
                StripeConfigReader.getConfigByName(
                    'DoesNotExist'
                )
            );

        System.assertEquals(
            false,
            missingConfig.get('success')
        );

        Map<String, Object> deleteMissing =
            parse(
                StripeConfigReader.deleteConfig(
                    'DoesNotExist'
                )
            );

        System.assertEquals(
            false,
            deleteMissing.get('success')
        );

        System.assertEquals(
            null,
            StripeConfigReader.getConfig(
                'DoesNotExist',
                'DoesNotExist'
            )
        );
    }

    @IsTest
    static void getConfig_fallsBackToObjectName() {
        createPaymentConfig(
            'AccountFallback',
            'Account',
            true
        );

        StripeConfigReader.PaymentConfig result =
            StripeConfigReader.getConfig(
                null,
                'Account'
            );

        System.assertNotEquals(null, result);
        System.assertEquals(
            'AccountFallback',
            result.configName
        );
        System.assertEquals(
            'Account',
            result.sourceObject
        );
    }

    @IsTest
    static void getConfig_ignoresInactiveConfig() {
        createPaymentConfig(
            'InactiveAccountConfig',
            'Account',
            false
        );

        StripeConfigReader.PaymentConfig result =
            StripeConfigReader.getConfig(
                'InactiveAccountConfig',
                'Account'
            );

        System.assertEquals(null, result);
    }

    @IsTest
    static void getConfigWithRecordValues_resolvesFields() {
        Stripe_Payment_Config__c config =
            createPaymentConfig(
                'AcctCfg',
                'Account',
                true
            );

        config.Amount_Field__c =
            'FIELD|NumberOfEmployees|true|false|false|Amount|1|true';
        config.Name_Field__c =
            'FIELD|Name|true|false|false|Name|2|true';
        update config;

        Account account = new Account(
            Name = 'Test Co',
            NumberOfEmployees = 250
        );
        insert account;

        Test.startTest();

        String responseJson =
            StripeConfigReader.getConfigWithRecordValues(
                account.Id,
                'Account',
                'AcctCfg'
            );

        Test.stopTest();

        Map<String, Object> response =
            parse(responseJson);

        System.assertEquals(
            true,
            response.get('success'),
            responseJson
        );

        Map<String, Object> fieldValues =
            (Map<String, Object>)
                response.get('fieldValues');

        System.assertEquals(
            'Test Co',
            fieldValues.get('Name_Field')
        );
        System.assertEquals(
            '250',
            String.valueOf(
                fieldValues.get('Amount_Field')
            )
        );
    }

    @IsTest
    static void getConfigWithRecordValues_hardcodedBlankAndRecordId() {
        createPaymentConfig(
            'HardcodedAccount',
            'Account',
            true
        );

        Account account =
            new Account(Name = 'Hardcoded Test');
        insert account;

        String responseJson =
            StripeConfigReader.getConfigWithRecordValues(
                account.Id,
                null,
                'HardcodedAccount'
            );

        Map<String, Object> response =
            parse(responseJson);

        System.assertEquals(
            true,
            response.get('success'),
            responseJson
        );

        Map<String, Object> values =
            (Map<String, Object>)
                response.get('fieldValues');

        System.assertEquals(
            '99.99',
            values.get('Amount_Field')
        );
        System.assertEquals(
            '',
            values.get('Email_Field')
        );
        System.assert(
            String.valueOf(
                values.get('Product_Info')
            ).contains(String.valueOf(account.Id))
        );
    }

    @IsTest
    static void getConfigWithRecordValues_resolvesQuickActionName() {
        Stripe_Payment_Config__c config =
            createPaymentConfig(
                'QuickActionConfig',
                'Account',
                true
            );

        config.QuickActionName__c =
            'Stripe_Account_Payment';
        update config;

        Account account =
            new Account(Name = 'Quick Action Test');
        insert account;

        Map<String, Object> response =
            parse(
                StripeConfigReader.getConfigWithRecordValues(
                    account.Id,
                    'Account',
                    'Stripe_Account_Payment'
                )
            );

        System.assertEquals(
            true,
            response.get('success')
        );

        Map<String, Object> configResult =
            (Map<String, Object>)
                response.get('config');

        System.assertEquals(
            'QuickActionConfig',
            configResult.get('configName')
        );
    }

    @IsTest
    static void getConfigWithRecordValues_missingConfig() {
        Account account =
            new Account(Name = 'No Config');
        insert account;

        Map<String, Object> response =
            parse(
                StripeConfigReader.getConfigWithRecordValues(
                    account.Id,
                    'Account',
                    'MissingConfig'
                )
            );

        System.assertEquals(
            false,
            response.get('success')
        );
        System.assert(
            String.valueOf(response.get('message'))
                .contains('No active Stripe Payment Config')
        );
    }

    @IsTest
    static void getConfigWithRecordValues_handlesInvalidField() {
        Stripe_Payment_Config__c config =
            createPaymentConfig(
                'InvalidFieldConfig',
                'Account',
                true
            );

        config.Amount_Field__c =
            'FIELD|Field_Does_Not_Exist__c|true|false|false|Amount|1|true';
        update config;

        Account account =
            new Account(Name = 'Invalid Field');
        insert account;

        Map<String, Object> response =
            parse(
                StripeConfigReader.getConfigWithRecordValues(
                    account.Id,
                    'Account',
                    'InvalidFieldConfig'
                )
            );

        System.assertEquals(
            true,
            response.get('success')
        );

        Map<String, Object> values =
            (Map<String, Object>)
                response.get('fieldValues');

        System.assertEquals(
            '',
            values.get('Amount_Field')
        );
    }

    @IsTest
    static void decodeFieldConfig_variants() {
        StripeConfigReader.FieldConfig legacy =
            StripeConfigReader.decodeFieldConfig('Name');

        System.assertEquals('FIELD', legacy.sourceType);
        System.assertEquals('Name', legacy.value);
        System.assertEquals(true, legacy.visible);
        System.assertEquals(false, legacy.required);
        System.assertEquals(false, legacy.readOnly);

        StripeConfigReader.FieldConfig full =
            StripeConfigReader.decodeFieldConfig(
                'HARDCODED|49.99|false|true|true|Amount|1|true'
            );

        System.assertEquals(
            'HARDCODED',
            full.sourceType
        );
        System.assertEquals('49.99', full.value);
        System.assertEquals(false, full.visible);
        System.assertEquals(true, full.required);
        System.assertEquals(true, full.readOnly);
        System.assertEquals('Amount', full.label);
        System.assertEquals(true, full.passToGateway);

        StripeConfigReader.FieldConfig partial =
            StripeConfigReader.decodeFieldConfig(
                'FIELD|Amount'
            );

        System.assertEquals('FIELD', partial.sourceType);
        System.assertEquals('Amount', partial.value);
        System.assertEquals(true, partial.visible);
        System.assertEquals(false, partial.passToGateway);

        StripeConfigReader.FieldConfig blank =
            StripeConfigReader.decodeFieldConfig('');

        System.assertEquals('BLANK', blank.sourceType);
        System.assertEquals('', blank.value);
        System.assertEquals(true, blank.visible);
    }

    @IsTest
    static void startWebhookConnectionTest_validation() {
        Map<String, Object> blankUrl =
            parse(
                StripeConfigReader.startWebhookConnectionTest(
                    null
                )
            );

        System.assertEquals(false, blankUrl.get('success'));
        System.assert(
            String.valueOf(blankUrl.get('message'))
                .contains('Webhook URL is required')
        );

        Map<String, Object> noCredentials =
            parse(
                StripeConfigReader.startWebhookConnectionTest(
                    'https://demo.my.site.com/services/apexrest/acxitech/stripe/webhook'
                )
            );

        System.assertEquals(
            false,
            noCredentials.get('success')
        );
        System.assert(
            String.valueOf(noCredentials.get('message'))
                .contains('credentials are not configured')
        );
    }

    @IsTest
    static void startWebhookConnectionTest_notRegistered() {
        createCredentials();

        Test.setMock(
            HttpCalloutMock.class,
            new ConfigReaderMock('NOT_REGISTERED')
        );

        Test.startTest();

        Map<String, Object> response =
            parse(
                StripeConfigReader.startWebhookConnectionTest(
                    'https://demo.my.site.com/services/apexrest/acxitech/stripe/webhook/'
                )
            );

        Test.stopTest();

        System.assertEquals(true, response.get('success'));
        System.assertEquals(
            false,
            response.get('connected')
        );
        System.assertEquals(
            false,
            response.get('pending')
        );
        System.assertEquals(
            'not_registered',
            response.get('status')
        );
    }

    @IsTest
    static void startWebhookConnectionTest_disabled() {
        createCredentials();

        Test.setMock(
            HttpCalloutMock.class,
            new ConfigReaderMock('DISABLED')
        );

        Test.startTest();

        Map<String, Object> response =
            parse(
                StripeConfigReader.startWebhookConnectionTest(
                    'https://demo.my.site.com/services/apexrest/acxitech/stripe/webhook'
                )
            );

        Test.stopTest();

        System.assertEquals(true, response.get('success'));
        System.assertEquals(
            'disabled',
            response.get('status')
        );
        System.assertEquals(
            'we_disabled',
            response.get('endpointId')
        );
    }

    @IsTest
    static void startWebhookConnectionTest_eventNotEnabled() {
        createCredentials();

        Test.setMock(
            HttpCalloutMock.class,
            new ConfigReaderMock(
                'EVENT_NOT_ENABLED'
            )
        );

        Test.startTest();

        Map<String, Object> response =
            parse(
                StripeConfigReader.startWebhookConnectionTest(
                    'https://demo.my.site.com/services/apexrest/acxitech/stripe/webhook'
                )
            );

        Test.stopTest();

        System.assertEquals(true, response.get('success'));
        System.assertEquals(
            'test_event_not_enabled',
            response.get('status')
        );
    }

    @IsTest
    static void startWebhookConnectionTest_endpointListFailure() {
        createCredentials();

        Test.setMock(
            HttpCalloutMock.class,
            new ConfigReaderMock(
                'ENDPOINT_LIST_ERROR'
            )
        );

        Test.startTest();

        Map<String, Object> response =
            parse(
                StripeConfigReader.startWebhookConnectionTest(
                    'https://demo.my.site.com/services/apexrest/acxitech/stripe/webhook'
                )
            );

        Test.stopTest();

        System.assertEquals(
            false,
            response.get('success')
        );
        System.assert(
            String.valueOf(response.get('message'))
                .contains('Unable to retrieve Stripe webhook endpoints')
        );
    }

    @IsTest
    static void startWebhookConnectionTest_pending() {
        createCredentials();

        Test.setMock(
            HttpCalloutMock.class,
            new ConfigReaderMock('CONNECTED')
        );

        Test.startTest();

        Map<String, Object> response =
            parse(
                StripeConfigReader.startWebhookConnectionTest(
                    'https://demo.my.site.com/services/apexrest/acxitech/stripe/webhook'
                )
            );

        Test.stopTest();

        System.assertEquals(true, response.get('success'));
        System.assertEquals(
            false,
            response.get('connected')
        );
        System.assertEquals(
            true,
            response.get('pending')
        );
        System.assertEquals(
            'pending',
            response.get('status')
        );
        System.assertNotEquals(
            null,
            response.get('token')
        );
        System.assertEquals(
            'cus_webhook_test',
            response.get('customerId')
        );
    }

    @IsTest
    static void startWebhookConnectionTest_customerCreationFailure() {
        createCredentials();

        Test.setMock(
            HttpCalloutMock.class,
            new ConfigReaderMock(
                'CUSTOMER_CREATE_ERROR'
            )
        );

        Test.startTest();

        Map<String, Object> response =
            parse(
                StripeConfigReader.startWebhookConnectionTest(
                    'https://demo.my.site.com/services/apexrest/acxitech/stripe/webhook'
                )
            );

        Test.stopTest();

        System.assertEquals(
            false,
            response.get('success')
        );
        System.assert(
            String.valueOf(response.get('message'))
                .contains('Unable to create Stripe webhook test event')
        );
    }

    @IsTest
    static void checkWebhookConnectionTest_requiresToken() {
        Map<String, Object> response =
            parse(
                StripeConfigReader.checkWebhookConnectionTest(
                    null,
                    null,
                    Datetime.now(),
                    'https://demo.my.site.com/webhook'
                )
            );

        System.assertEquals(
            false,
            response.get('success')
        );
        System.assert(
            String.valueOf(response.get('message'))
                .contains('Webhook test token is required')
        );
    }

    @IsTest
    static void checkWebhookConnectionTest_pending() {
        Datetime requestedAt = Datetime.now();

        Map<String, Object> response =
            parse(
                StripeConfigReader.checkWebhookConnectionTest(
                    'pending_token',
                    null,
                    requestedAt,
                    'https://demo.my.site.com/webhook'
                )
            );

        System.assertEquals(true, response.get('success'));
        System.assertEquals(
            false,
            response.get('connected')
        );
        System.assertEquals(
            true,
            response.get('pending')
        );
        System.assertEquals(
            'pending',
            response.get('status')
        );
    }

    @IsTest
    static void checkWebhookConnectionTest_timeout() {
        Map<String, Object> response =
            parse(
                StripeConfigReader.checkWebhookConnectionTest(
                    'timeout_token',
                    null,
                    Datetime.now().addMinutes(-1),
                    'https://demo.my.site.com/webhook'
                )
            );

        System.assertEquals(true, response.get('success'));
        System.assertEquals(
            false,
            response.get('connected')
        );
        System.assertEquals(
            false,
            response.get('pending')
        );
        System.assertEquals(
            'delivery_failed',
            response.get('status')
        );
    }

    @IsTest
    static void checkWebhookConnectionTest_ignoresInvalidLogs() {
        String token = 'valid_token';

        insert new List<Stripe_Webhook_Log__c>{
            new Stripe_Webhook_Log__c(
                Event_Id__c = 'evt_blank_payload',
                Event_Type__c = 'customer.created',
                Payload__c = null,
                Signature_Verified__c = true,
                Processing_Status__c = 'Processed'
            ),
            new Stripe_Webhook_Log__c(
                Event_Id__c = 'evt_bad_json',
                Event_Type__c = 'customer.created',
                Payload__c = '{invalid-json',
                Signature_Verified__c = true,
                Processing_Status__c = 'Processed'
            ),
            new Stripe_Webhook_Log__c(
                Event_Id__c = 'evt_wrong_token',
                Event_Type__c = 'customer.created',
                Payload__c =
                    createWebhookPayload('another_token'),
                Signature_Verified__c = true,
                Processing_Status__c = 'Processed'
            )
        };

        Map<String, Object> response =
            parse(
                StripeConfigReader.checkWebhookConnectionTest(
                    token,
                    null,
                    Datetime.now(),
                    'https://demo.my.site.com/webhook'
                )
            );

        System.assertEquals(true, response.get('success'));
        System.assertEquals(
            'pending',
            response.get('status')
        );
    }

    @IsTest
    static void checkWebhookConnectionTest_signatureFailed() {
        String token = 'signature_token';

        insert new Stripe_Webhook_Log__c(
            Event_Id__c = 'evt_signature_failed',
            Event_Type__c = 'customer.created',
            Payload__c = createWebhookPayload(token),
            Signature_Verified__c = false,
            Processing_Status__c = 'Processed'
        );

        Map<String, Object> response =
            parse(
                StripeConfigReader.checkWebhookConnectionTest(
                    token,
                    'cus_webhook_test',
                    Datetime.now(),
                    'https://demo.my.site.com/webhook'
                )
            );

        System.assertEquals(true, response.get('success'));
        System.assertEquals(
            false,
            response.get('connected')
        );
        System.assertEquals(
            'signature_failed',
            response.get('status')
        );
        System.assertEquals(
            'evt_signature_failed',
            response.get('eventId')
        );
    }

    @IsTest
    static void checkWebhookConnectionTest_processingFailed() {
        String token = 'processing_token';

        insert new Stripe_Webhook_Log__c(
            Event_Id__c = 'evt_processing_failed',
            Event_Type__c = 'customer.created',
            Payload__c = createWebhookPayload(token),
            Signature_Verified__c = true,
            Processing_Status__c = 'Error',
            Error_Message__c = 'Test processing failure'
        );

        Map<String, Object> response =
            parse(
                StripeConfigReader.checkWebhookConnectionTest(
                    token,
                    null,
                    Datetime.now(),
                    'https://demo.my.site.com/webhook'
                )
            );

        System.assertEquals(true, response.get('success'));
        System.assertEquals(
            false,
            response.get('connected')
        );
        System.assertEquals(
            'processing_failed',
            response.get('status')
        );
        System.assert(
            String.valueOf(response.get('message'))
                .contains('Test processing failure')
        );
    }

    @IsTest
    static void checkWebhookConnectionTest_connected() {
        String token = 'connected_token';

        insert new Stripe_Webhook_Log__c(
            Event_Id__c = 'evt_connected',
            Event_Type__c = 'customer.created',
            Payload__c = createWebhookPayload(token),
            Signature_Verified__c = true,
            Processing_Status__c = 'Processed'
        );

        Test.setMock(
            HttpCalloutMock.class,
            new ConfigReaderMock('CONNECTED')
        );

        Test.startTest();

        Map<String, Object> response =
            parse(
                StripeConfigReader.checkWebhookConnectionTest(
                    token,
                    'cus_webhook_test',
                    Datetime.now(),
                    'https://demo.my.site.com/webhook'
                )
            );

        Test.stopTest();

        System.assertEquals(true, response.get('success'));
        System.assertEquals(
            true,
            response.get('connected')
        );
        System.assertEquals(
            false,
            response.get('pending')
        );
        System.assertEquals(
            'connected',
            response.get('status')
        );
        System.assertEquals(
            'evt_connected',
            response.get('eventId')
        );
    }
}