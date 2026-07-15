@isTest
private class StripeConfigReaderTest {

    @isTest static void credentials_saveAndInfo_noSecretExposed() {
        Test.startTest();
        String save = StripeConfigReader.saveCredentials(JSON.serialize(new Map<String, Object>{
            'environment' => 'test',
            'publishableKeyTest' => 'pk_test_abc',
            'secretKeyTest' => 'sk_test_supersecretvalue',
            'webhookSecretTest' => 'whsec_a, whsec_b',
            'hostedEnabled' => true
        }));
        Test.stopTest();
        System.assert(((Map<String,Object>) JSON.deserializeUntyped(save)).get('success') == true);

        String info = StripeConfigReader.getCredentialsInfo();
        Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(info);
        System.assertEquals(true, m.get('isConfigured'));
        System.assertEquals('pk_test_abc', m.get('publishableKey'));
        System.assertEquals(true, m.get('secretKeySet'));
        System.assert(!info.contains('supersecretvalue'), 'The raw secret key must never be exposed to clients');

        List<String> secrets = StripeConfigReader.getWebhookSecrets();
        System.assertEquals(2, secrets.size(), 'rotation: two secrets parsed');
    }

    @isTest static void testConnection_ok() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String res = StripeConfigReader.testConnection();
        Test.stopTest();
        System.assertEquals(true, ((Map<String,Object>) JSON.deserializeUntyped(res)).get('success'), res);
    }

    @isTest static void registerWebhook_savesSecret() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Credentials__c cr = Stripe_Credentials__c.getOrgDefaults();
        cr.Webhook_Base_Url__c = 'https://demo.my.site.com';   // public Site (not org login domain)
        update cr;
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String res = StripeConfigReader.registerWebhook();
        Test.stopTest();
        System.assertEquals(true, ((Map<String,Object>) JSON.deserializeUntyped(res)).get('success'), res);
        List<String> secrets = StripeConfigReader.getWebhookSecrets();
        System.assertEquals('whsec_test_registered', secrets[0], 'signing secret auto-saved from Stripe');
    }

    @isTest static void getCredentials_resolvesEnvironment() {
        StripeTestDataFactory.setupCredentials();
        StripeConfigReader.Credentials c = StripeConfigReader.getCredentials();
        System.assertEquals('test', c.environment);
        System.assertEquals('sk_test_123', c.secretKey);
        System.assertEquals('pk_test_123', c.publishableKey);
        System.assertEquals(1, c.webhookSecrets.size());
    }

    @isTest static void config_crud() {
        Test.startTest();
        String save = StripeConfigReader.saveConfig(JSON.serialize(new Map<String, Object>{
            'Name' => 'OppPay', 'Source_Object' => 'Opportunity', 'Checkout_Mode' => 'HOSTED',
            'Payment_Type' => 'One-Time', 'Amount_Field' => 'FIELD|Amount|true|false|false|Amt|1|true',
            'Currency' => 'usd', 'Is_Active' => true
        }));
        Test.stopTest();
        System.assert(((Map<String,Object>) JSON.deserializeUntyped(save)).get('success') == true);

        String byName = StripeConfigReader.getConfigByName('OppPay');
        System.assert(((Map<String,Object>) JSON.deserializeUntyped(byName)).get('success') == true);

        String all = StripeConfigReader.getAllConfigs();
        System.assert(all.contains('OppPay'));

        StripeConfigReader.PaymentConfig pc = StripeConfigReader.getConfig('OppPay', 'Opportunity');
        System.assertEquals('HOSTED', pc.checkoutMode);

        String del = StripeConfigReader.deleteConfig('OppPay');
        System.assert(((Map<String,Object>) JSON.deserializeUntyped(del)).get('success') == true);
    }

    @isTest static void getConfigWithRecordValues_resolvesFields() {
        StripeTestDataFactory.setupConfig('AcctCfg', 'Account', 'HOSTED');
        Account a = StripeTestDataFactory.makeAccount();
        Test.startTest();
        String resJson = StripeConfigReader.getConfigWithRecordValues(a.Id, 'Account', 'AcctCfg');
        Test.stopTest();
        Map<String, Object> r = (Map<String, Object>) JSON.deserializeUntyped(resJson);
        System.assertEquals(true, r.get('success'), resJson);
        Map<String, Object> fv = (Map<String, Object>) r.get('fieldValues');
        System.assertEquals('Test Co', fv.get('Name_Field'));
        System.assertEquals('250', String.valueOf(fv.get('Amount_Field')));
    }

    @isTest static void decodeFieldConfig_variants() {
        StripeConfigReader.FieldConfig legacy = StripeConfigReader.decodeFieldConfig('Name');
        System.assertEquals('FIELD', legacy.sourceType);
        StripeConfigReader.FieldConfig full = StripeConfigReader.decodeFieldConfig('HARDCODED|49.99|true|true|false|Amount|1|true');
        System.assertEquals('HARDCODED', full.sourceType);
        System.assertEquals('49.99', full.value);
        System.assert(full.passToGateway);
        StripeConfigReader.FieldConfig blank = StripeConfigReader.decodeFieldConfig('');
        System.assertEquals('BLANK', blank.sourceType);
    }
}