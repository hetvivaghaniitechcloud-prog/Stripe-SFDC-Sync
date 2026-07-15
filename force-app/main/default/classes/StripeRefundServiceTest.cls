@isTest
private class StripeRefundServiceTest {

    @isTest static void refund_full() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Payment__c p = new Stripe_Payment__c(Payment_Intent_Id__c = 'pi_1', Amount__c = 19.99, Status__c = 'Completed');
        insert p;
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String res = StripeRefundService.createRefund(p.Id, null, 'requested_by_customer');
        Test.stopTest();
        Map<String, Object> r = (Map<String, Object>) JSON.deserializeUntyped(res);
        System.assertEquals(true, r.get('success'), res);
        Stripe_Payment__c u = [SELECT Status__c, Refunded_Amount__c FROM Stripe_Payment__c WHERE Id = :p.Id];
        System.assertEquals('Refunded', u.Status__c);
        // refund API response stored in the received trail with its raw response
        Stripe_Payment_Received__c rec = [SELECT Status__c, Amount_Received__c, Raw_Payload__c, Event_Type__c
                                          FROM Stripe_Payment_Received__c WHERE Payment__c = :p.Id LIMIT 1];
        System.assertEquals('refund.api', rec.Event_Type__c);
        System.assertEquals('Refunded', rec.Status__c);
        System.assertEquals(-19.99, rec.Amount_Received__c);
        System.assert(rec.Raw_Payload__c != null && rec.Raw_Payload__c.contains('re_test_123'), 'raw refund response stored');
    }

    @isTest static void refund_partial() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Payment__c p = new Stripe_Payment__c(Charge_Id__c = 'ch_1', Amount__c = 100, Status__c = 'Completed');
        insert p;
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String res = StripeRefundService.createRefund(p.Id, 25, null);
        Test.stopTest();
        System.assertEquals(true, ((Map<String,Object>) JSON.deserializeUntyped(res)).get('success'));
        Stripe_Payment__c u = [SELECT Status__c, Refunded_Amount__c FROM Stripe_Payment__c WHERE Id = :p.Id];
        System.assertEquals('Partial Refunded', u.Status__c);
        System.assertEquals(25, u.Refunded_Amount__c);
    }

    @isTest static void refund_noStripeId() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Payment__c p = new Stripe_Payment__c(Amount__c = 10, Status__c = 'Initiated');
        insert p;
        Test.startTest();
        String res = StripeRefundService.createRefund(p.Id, null, null);
        Test.stopTest();
        System.assertEquals(false, ((Map<String,Object>) JSON.deserializeUntyped(res)).get('success'));
    }

    @isTest static void getRefund_lookup() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String res = StripeRefundService.getRefund('re_1');
        Test.stopTest();
        System.assertEquals(true, ((Map<String,Object>) JSON.deserializeUntyped(res)).get('success'));
    }
}