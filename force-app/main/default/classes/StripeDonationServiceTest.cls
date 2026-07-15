@isTest
private class StripeDonationServiceTest {

    @isTest static void contactInfo_fallbackForNoContact() {
        Map<String, Object> info = StripeDonationService.getMyContactInfo();
        System.assertEquals(false, info.get('hasContact'));
        System.assert(info.containsKey('email'));
    }

    @isTest static void donation_withReturnUrl_forUpi() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        // Passing a returnUrl switches the session to redirect_on_completion:if_required
        // so redirect-based methods (UPI) become available; still succeeds & unchanged for card.
        String res = StripeDonationService.createDonationCheckout(
            100, 'inr', 'one-time', 'Jane Doe', 'jane@x.com', 'General Fund', null,
            'https://example.my.site.com/resource/stripeCheckoutFrame/index.html?stripe_return=1');
        Test.stopTest();
        Map<String, Object> r = (Map<String, Object>) JSON.deserializeUntyped(res);
        System.assertEquals(true, r.get('success'), res);
        System.assertEquals('cs_test_123_secret', r.get('clientSecret'));
    }

    @isTest static void donation_oneTime() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String res = StripeDonationService.createDonationCheckout(100, 'usd', 'one-time', 'Jane Doe', 'jane@x.com', 'General Fund');
        Test.stopTest();
        Map<String, Object> r = (Map<String, Object>) JSON.deserializeUntyped(res);
        System.assertEquals(true, r.get('success'), res);
        System.assertEquals('cs_test_123_secret', r.get('clientSecret'));
        System.assertEquals('pk_test_123', r.get('publishableKey'));
        Stripe_Payment__c p = [SELECT Payment_Type__c, Amount__c, Checkout_Mode__c FROM Stripe_Payment__c LIMIT 1];
        System.assertEquals('One-Time', p.Payment_Type__c);
        System.assertEquals('EMBEDDED', p.Checkout_Mode__c);
        System.assertEquals(100, p.Amount__c);
    }

    @isTest static void donation_monthlyRecurring() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String res = StripeDonationService.createDonationCheckout(25, 'usd', 'month', 'Jane', 'jane@x.com', null);
        Test.stopTest();
        Map<String, Object> r = (Map<String, Object>) JSON.deserializeUntyped(res);
        System.assertEquals(true, r.get('success'), res);
        Stripe_Payment__c p = [SELECT Payment_Type__c FROM Stripe_Payment__c LIMIT 1];
        System.assertEquals('Recurring', p.Payment_Type__c);
    }

    @isTest static void donation_yearlyRecurring() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String res = StripeDonationService.createDonationCheckout(500, 'usd', 'year', 'Jane', 'jane@x.com', 'Programs');
        Test.stopTest();
        System.assertEquals(true, ((Map<String,Object>) JSON.deserializeUntyped(res)).get('success'), res);
    }

    @isTest static void donation_invalidAmount() {
        StripeTestDataFactory.setupCredentials();
        Test.startTest();
        String res = StripeDonationService.createDonationCheckout(0, 'usd', 'one-time', 'X', 'x@y.com', null);
        Test.stopTest();
        System.assertEquals(false, ((Map<String,Object>) JSON.deserializeUntyped(res)).get('success'));
    }

    @isTest static void donation_noCredentials() {
        Test.startTest();
        String res = StripeDonationService.createDonationCheckout(50, 'usd', 'one-time', 'X', 'x@y.com', null);
        Test.stopTest();
        System.assertEquals(false, ((Map<String,Object>) JSON.deserializeUntyped(res)).get('success'));
    }
}