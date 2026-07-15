@isTest
private class StripeWebhookHandlerTest {

    private static Long nowEpoch() { return DateTime.now().getTime() / 1000; }

    @isTest static void verify_validSignature_accepts() {
        String payload = '{"id":"evt_1","type":"checkout.session.completed"}';
        Long ts = nowEpoch();
        String header = StripeTestDataFactory.signPayload(payload, StripeTestDataFactory.WEBHOOK_SECRET, ts);
        StripeWebhookHandler.VerifyResult r = StripeWebhookHandler.verifySignature(
            payload, header, new List<String>{ StripeTestDataFactory.WEBHOOK_SECRET }, 300, ts);
        System.assert(r.verified, 'Valid signature should be accepted: ' + r.message);
    }

    @isTest static void verify_tamperedPayload_rejects() {
        String payload = '{"id":"evt_1","type":"checkout.session.completed"}';
        Long ts = nowEpoch();
        String header = StripeTestDataFactory.signPayload(payload, StripeTestDataFactory.WEBHOOK_SECRET, ts);
        StripeWebhookHandler.VerifyResult r = StripeWebhookHandler.verifySignature(
            payload + 'TAMPER', header, new List<String>{ StripeTestDataFactory.WEBHOOK_SECRET }, 300, ts);
        System.assert(!r.verified, 'Tampered payload must be rejected');
    }

    @isTest static void verify_staleTimestamp_rejects() {
        String payload = '{"id":"evt_1"}';
        Long ts = nowEpoch() - 1000; // outside 300s tolerance
        String header = StripeTestDataFactory.signPayload(payload, StripeTestDataFactory.WEBHOOK_SECRET, ts);
        StripeWebhookHandler.VerifyResult r = StripeWebhookHandler.verifySignature(
            payload, header, new List<String>{ StripeTestDataFactory.WEBHOOK_SECRET }, 300, nowEpoch());
        System.assert(!r.verified, 'Stale event must be rejected');
        System.assertEquals('Rejected - Stale', r.status);
    }

    @isTest static void verify_rotation_acceptsSecondSecret() {
        String payload = '{"id":"evt_1"}';
        Long ts = nowEpoch();
        String header = StripeTestDataFactory.signPayload(payload, 'whsec_new_secret', ts);
        StripeWebhookHandler.VerifyResult r = StripeWebhookHandler.verifySignature(
            payload, header, new List<String>{ 'whsec_old_secret', 'whsec_new_secret' }, 300, ts);
        System.assert(r.verified, 'Either active secret should verify (rotation)');
    }

    @isTest static void verify_missingHeader_rejects() {
        StripeWebhookHandler.VerifyResult r = StripeWebhookHandler.verifySignature(
            '{}', null, new List<String>{ 'whsec_x' }, 300, nowEpoch());
        System.assert(!r.verified);
    }

    @isTest static void verify_noSecretConfigured_rejects() {
        StripeWebhookHandler.VerifyResult r = StripeWebhookHandler.verifySignature(
            '{}', 't=1,v1=abc', new List<String>(), 300, nowEpoch());
        System.assert(!r.verified);
    }

    @isTest static void handleWebhook_checkoutCompleted_marksPaymentCompleted() {
        StripeTestDataFactory.setupCredentials();
        StripeTestDataFactory.setupConfig('Cfg', 'Account', 'HOSTED');
        Account a = StripeTestDataFactory.makeAccount();
        Stripe_Payment__c p = new Stripe_Payment__c(
            Checkout_Session_Id__c = 'cs_evt_1', Status__c = 'Initiated',
            Source_Object__c = 'Account', Source_Record_Id__c = a.Id, Config_Name__c = 'Cfg');
        insert p;

        String payload = '{"id":"evt_co_1","type":"checkout.session.completed","data":{"object":'
            + '{"id":"cs_evt_1","object":"checkout.session","payment_status":"paid","status":"complete",'
            + '"payment_intent":"pi_evt_1","customer":"cus_evt_1","client_reference_id":"' + a.Id + '"}}}';
        Long ts = nowEpoch();
        String header = StripeTestDataFactory.signPayload(payload, StripeTestDataFactory.WEBHOOK_SECRET, ts);

        Test.startTest();
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/stripe/webhook';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(payload);
        req.headers.put('Stripe-Signature', header);
        RestContext.request = req;
        RestContext.response = new RestResponse();
        StripeWebhookHandler.handleWebhook();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        Stripe_Payment__c updated = [SELECT Status__c, Payment_Intent_Id__c, Signature_Verified__c
                                     FROM Stripe_Payment__c WHERE Id = :p.Id];
        System.assertEquals('Completed', updated.Status__c);
        System.assertEquals('pi_evt_1', updated.Payment_Intent_Id__c);
        System.assert(updated.Signature_Verified__c);
        System.assertEquals(1, [SELECT COUNT() FROM Stripe_Webhook_Log__c WHERE Event_Id__c = 'evt_co_1']);
    }

    @isTest static void handleWebhook_subscriptionCheckout_noDuplicateFirstRow() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Payment__c p = new Stripe_Payment__c(Checkout_Session_Id__c='cs_sub1', Status__c='Initiated',
            Payment_Type__c='Recurring', Source_Object__c='Account', Source_Record_Id__c='001x');
        insert p;
        Test.startTest();
        // Subscription checkout: the first payment also arrives as invoice.paid, so
        // checkout.session.completed must NOT create its own received row.
        fireEvent('{"id":"evt_subco","type":"checkout.session.completed","data":{"object":'
            + '{"id":"cs_sub1","object":"checkout.session","payment_status":"paid","status":"complete",'
            + '"subscription":"sub_co1","amount_total":3000,"currency":"inr"}}}');
        Test.stopTest();
        System.assertEquals('Completed', [SELECT Status__c FROM Stripe_Payment__c WHERE Id=:p.Id].Status__c);
        System.assertEquals(0, [SELECT COUNT() FROM Stripe_Payment_Received__c WHERE Event_Id__c='evt_subco'],
            'subscription checkout should not create a duplicate first-cycle received row');
    }

    @isTest static void handleWebhook_duplicateEvent_returns200() {
        StripeTestDataFactory.setupCredentials();
        insert new Stripe_Webhook_Log__c(Event_Id__c = 'evt_dup', Event_Type__c = 'x', Signature_Verified__c = true);

        String payload = '{"id":"evt_dup","type":"payment_intent.succeeded","data":{"object":{"id":"pi_x"}}}';
        Long ts = nowEpoch();
        String header = StripeTestDataFactory.signPayload(payload, StripeTestDataFactory.WEBHOOK_SECRET, ts);

        Test.startTest();
        RestRequest req = new RestRequest();
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(payload);
        req.headers.put('Stripe-Signature', header);
        RestContext.request = req;
        RestContext.response = new RestResponse();
        StripeWebhookHandler.handleWebhook();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(1, [SELECT COUNT() FROM Stripe_Webhook_Log__c WHERE Event_Id__c = 'evt_dup']);
    }

    @isTest static void handleWebhook_invalidSignature_returns400() {
        StripeTestDataFactory.setupCredentials();
        String payload = '{"id":"evt_bad","type":"payment_intent.succeeded","data":{"object":{"id":"pi_x"}}}';

        Test.startTest();
        RestRequest req = new RestRequest();
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(payload);
        req.headers.put('Stripe-Signature', 't=' + nowEpoch() + ',v1=deadbeef');
        RestContext.request = req;
        RestContext.response = new RestResponse();
        StripeWebhookHandler.handleWebhook();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode);
        Stripe_Webhook_Log__c log = [SELECT Signature_Verified__c, Processing_Status__c
                                     FROM Stripe_Webhook_Log__c WHERE Event_Id__c = 'evt_bad'];
        System.assert(!log.Signature_Verified__c);
    }

    @isTest static void handleWebhook_paymentIntentSucceeded_updates() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Payment__c p = new Stripe_Payment__c(Payment_Intent_Id__c = 'pi_evt_2', Status__c = 'Initiated');
        insert p;
        String payload = '{"id":"evt_pi_2","type":"payment_intent.succeeded","data":{"object":'
            + '{"id":"pi_evt_2","status":"succeeded","latest_charge":"ch_2"}}}';
        Long ts = nowEpoch();
        String header = StripeTestDataFactory.signPayload(payload, StripeTestDataFactory.WEBHOOK_SECRET, ts);

        Test.startTest();
        RestRequest req = new RestRequest();
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(payload);
        req.headers.put('Stripe-Signature', header);
        RestContext.request = req;
        RestContext.response = new RestResponse();
        StripeWebhookHandler.handleWebhook();
        Test.stopTest();

        Stripe_Payment__c updated = [SELECT Status__c, Charge_Id__c FROM Stripe_Payment__c WHERE Id = :p.Id];
        System.assertEquals('Completed', updated.Status__c);
        System.assertEquals('ch_2', updated.Charge_Id__c);
        Stripe_Payment_Received__c rcv = [SELECT Status__c, Payment__c FROM Stripe_Payment_Received__c WHERE Event_Id__c = 'evt_pi_2'];
        System.assertEquals('Succeeded', rcv.Status__c);
        System.assertEquals(p.Id, rcv.Payment__c);
    }

    @isTest static void handleWebhook_receivedTrail_failedThenSucceeded() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Payment__c p = new Stripe_Payment__c(Payment_Intent_Id__c = 'pi_trail', Status__c = 'Initiated');
        insert p;
        Test.startTest();
        fireEvent('{"id":"evt_fail_1","type":"payment_intent.payment_failed","data":{"object":{"id":"pi_trail","status":"requires_payment_method","amount":5000,"currency":"usd","last_payment_error":{"message":"Card declined"}}}}');
        fireEvent('{"id":"evt_ok_1","type":"payment_intent.succeeded","data":{"object":{"id":"pi_trail","status":"succeeded","amount":5000,"currency":"usd"}}}');
        Test.stopTest();
        // both attempts recorded on the SAME payment
        List<Stripe_Payment_Received__c> rows = [SELECT Status__c, Amount_Received__c, Failure_Message__c FROM Stripe_Payment_Received__c WHERE Payment__c = :p.Id ORDER BY CreatedDate];
        System.assertEquals(2, rows.size(), 'both the failed and successful attempts should be stored');
        System.assertEquals('Failed', rows[0].Status__c);
        System.assertEquals('Card declined', rows[0].Failure_Message__c);
        System.assertEquals('Succeeded', rows[1].Status__c);
        System.assertEquals(50, rows[1].Amount_Received__c);
    }

    private static void fireEvent(String payload) {
        Long ts = nowEpoch();
        String header = StripeTestDataFactory.signPayload(payload, StripeTestDataFactory.WEBHOOK_SECRET, ts);
        RestRequest req = new RestRequest();
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(payload);
        req.headers.put('Stripe-Signature', header);
        RestContext.request = req;
        RestContext.response = new RestResponse();
        StripeWebhookHandler.handleWebhook();
    }

    @isTest static void handleWebhook_paymentIntentFailed() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Payment__c p = new Stripe_Payment__c(Payment_Intent_Id__c = 'pi_f', Status__c = 'Initiated');
        insert p;
        Test.startTest();
        fireEvent('{"id":"evt_f","type":"payment_intent.payment_failed","data":{"object":{"id":"pi_f","status":"requires_payment_method"}}}');
        Test.stopTest();
        System.assertEquals('Failed', [SELECT Status__c FROM Stripe_Payment__c WHERE Id = :p.Id].Status__c);
    }

    @isTest static void handleWebhook_failedCheckoutAttempt_linksAndRecords() {
        StripeTestDataFactory.setupCredentials();
        // Checkout-mode payment: has a session id, no PI id yet (as in real life before completion)
        Stripe_Payment__c p = new Stripe_Payment__c(Checkout_Session_Id__c = 'cs_fa', Source_Record_Id__c = '001failtest',
            Status__c = 'Initiated', Checkout_Mode__c = 'EMBEDDED');
        insert p;
        Test.startTest();
        fireEvent('{"id":"evt_pi_fail","type":"payment_intent.payment_failed","data":{"object":'
            + '{"id":"pi_failattempt","status":"requires_payment_method","amount":5000,"currency":"inr",'
            + '"metadata":{"sf_record_id":"001failtest"},"last_payment_error":{"message":"Your card was declined."}}}}');
        Test.stopTest();
        Stripe_Payment__c u = [SELECT Status__c, Payment_Intent_Id__c FROM Stripe_Payment__c WHERE Id = :p.Id];
        System.assertEquals('Failed', u.Status__c);
        System.assertEquals('pi_failattempt', u.Payment_Intent_Id__c, 'PI linked via metadata for future events');
        Stripe_Payment_Received__c r = [SELECT Status__c, Failure_Message__c, Payment__c FROM Stripe_Payment_Received__c WHERE Event_Id__c = 'evt_pi_fail'];
        System.assertEquals('Failed', r.Status__c);
        System.assertEquals('Your card was declined.', r.Failure_Message__c);
        System.assertEquals(p.Id, r.Payment__c);
    }

    @isTest static void handleWebhook_checkoutExpired_marksCancelled() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Payment__c p = new Stripe_Payment__c(Checkout_Session_Id__c = 'cs_exp', Status__c = 'Initiated', Checkout_Mode__c = 'EMBEDDED');
        insert p;
        Test.startTest();
        fireEvent('{"id":"evt_exp","type":"checkout.session.expired","data":{"object":{"id":"cs_exp","amount_total":5000,"currency":"inr"}}}');
        Test.stopTest();
        System.assertEquals('Cancelled', [SELECT Status__c FROM Stripe_Payment__c WHERE Id = :p.Id].Status__c);
        System.assertEquals('Cancelled', [SELECT Status__c FROM Stripe_Payment_Received__c WHERE Event_Id__c = 'evt_exp'].Status__c);
    }

    @isTest static void handleWebhook_chargeRefunded() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Payment__c p = new Stripe_Payment__c(Payment_Intent_Id__c = 'pi_r', Amount__c = 100, Status__c = 'Completed');
        insert p;
        Test.startTest();
        fireEvent('{"id":"evt_r","type":"charge.refunded","data":{"object":{"id":"ch_r","payment_intent":"pi_r","amount_refunded":10000,"refunded":true}}}');
        Test.stopTest();
        Stripe_Payment__c u = [SELECT Status__c, Refunded_Amount__c FROM Stripe_Payment__c WHERE Id = :p.Id];
        System.assertEquals('Refunded', u.Status__c);
        System.assertEquals(100, u.Refunded_Amount__c);
    }

    @isTest static void handleWebhook_invoicePaidAndFailed() {
        StripeTestDataFactory.setupCredentials();
        insert new Stripe_Subscription__c(Subscription_Id__c = 'sub_inv', Status__c = 'active');
        Test.startTest();
        fireEvent('{"id":"evt_inv1","type":"invoice.payment_failed","data":{"object":{"id":"in_1","subscription":"sub_inv"}}}');
        Test.stopTest();
        System.assertEquals('past_due', [SELECT Status__c FROM Stripe_Subscription__c WHERE Subscription_Id__c = 'sub_inv'].Status__c);
    }

    @isTest static void handleWebhook_unroutedType_stillLogged() {
        StripeTestDataFactory.setupCredentials();
        Test.startTest();
        fireEvent('{"id":"evt_other","type":"customer.created","data":{"object":{"id":"cus_x"}}}');
        Test.stopTest();
        Stripe_Webhook_Log__c log = [SELECT Processing_Status__c, Signature_Verified__c FROM Stripe_Webhook_Log__c WHERE Event_Id__c = 'evt_other'];
        System.assert(log.Signature_Verified__c);
        System.assertEquals('Processed', log.Processing_Status__c);
    }

    // ═══════════════════ New comprehensive event coverage ═══════════════════

    @isTest static void handleWebhook_paymentIntentProcessing() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Payment__c p = new Stripe_Payment__c(Payment_Intent_Id__c = 'pi_proc', Status__c = 'Initiated');
        insert p;
        Test.startTest();
        fireEvent('{"id":"evt_proc","type":"payment_intent.processing","data":{"object":{"id":"pi_proc","status":"processing","amount":7500,"currency":"inr"}}}');
        Test.stopTest();
        System.assertEquals('Processing', [SELECT Status__c FROM Stripe_Payment__c WHERE Id = :p.Id].Status__c);
        System.assertEquals('Processing', [SELECT Status__c FROM Stripe_Payment_Received__c WHERE Event_Id__c = 'evt_proc'].Status__c);
    }

    @isTest static void handleWebhook_paymentIntentRequiresAction() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Payment__c p = new Stripe_Payment__c(Payment_Intent_Id__c = 'pi_ra', Status__c = 'Initiated');
        insert p;
        Test.startTest();
        fireEvent('{"id":"evt_ra","type":"payment_intent.requires_action","data":{"object":{"id":"pi_ra","status":"requires_action"}}}');
        Test.stopTest();
        System.assertEquals('Requires Action', [SELECT Status__c FROM Stripe_Payment__c WHERE Id = :p.Id].Status__c);
    }

    @isTest static void handleWebhook_paymentIntentCanceled() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Payment__c p = new Stripe_Payment__c(Payment_Intent_Id__c = 'pi_can', Status__c = 'Pending');
        insert p;
        Test.startTest();
        fireEvent('{"id":"evt_can","type":"payment_intent.canceled","data":{"object":{"id":"pi_can","status":"canceled"}}}');
        Test.stopTest();
        System.assertEquals('Cancelled', [SELECT Status__c FROM Stripe_Payment__c WHERE Id = :p.Id].Status__c);
        System.assertEquals('Cancelled', [SELECT Status__c FROM Stripe_Payment_Received__c WHERE Event_Id__c = 'evt_can'].Status__c);
    }

    @isTest static void handleWebhook_chargeSucceeded_recordsAttempt() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Payment__c p = new Stripe_Payment__c(Payment_Intent_Id__c = 'pi_ch', Status__c = 'Completed');
        insert p;
        Test.startTest();
        fireEvent('{"id":"evt_ch","type":"charge.succeeded","data":{"object":{"id":"ch_s","payment_intent":"pi_ch","amount":9000,"currency":"inr","payment_method_details":{"type":"card"}}}}');
        Test.stopTest();
        Stripe_Payment_Received__c r = [SELECT Status__c, Payment_Method__c, Payment__c FROM Stripe_Payment_Received__c WHERE Event_Id__c = 'evt_ch'];
        System.assertEquals('Succeeded', r.Status__c);
        System.assertEquals('card', r.Payment_Method__c);
        System.assertEquals(p.Id, r.Payment__c);
    }

    @isTest static void handleWebhook_disputeCreatedAndLost() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Payment__c p = new Stripe_Payment__c(Payment_Intent_Id__c = 'pi_dsp', Charge_Id__c = 'ch_dsp', Status__c = 'Completed');
        insert p;
        Test.startTest();
        fireEvent('{"id":"evt_dsp1","type":"charge.dispute.created","data":{"object":{"id":"dp_1","charge":"ch_dsp","payment_intent":"pi_dsp","amount":9000,"currency":"inr","reason":"fraudulent","status":"needs_response"}}}');
        fireEvent('{"id":"evt_dsp2","type":"charge.dispute.closed","data":{"object":{"id":"dp_1","charge":"ch_dsp","payment_intent":"pi_dsp","amount":9000,"currency":"inr","status":"lost"}}}');
        Test.stopTest();
        System.assertEquals('Refunded', [SELECT Status__c FROM Stripe_Payment__c WHERE Id = :p.Id].Status__c, 'A lost dispute reverses the funds');
        System.assertEquals('Disputed', [SELECT Status__c FROM Stripe_Payment_Received__c WHERE Event_Id__c = 'evt_dsp1'].Status__c);
        System.assertEquals(2, [SELECT COUNT() FROM Stripe_Payment_Received__c WHERE Payment__c = :p.Id]);
    }

    @isTest static void handleWebhook_refundCreated_recordsNegative() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Payment__c p = new Stripe_Payment__c(Payment_Intent_Id__c = 'pi_rf', Charge_Id__c = 'ch_rf', Status__c = 'Completed');
        insert p;
        Test.startTest();
        fireEvent('{"id":"evt_rf","type":"refund.created","data":{"object":{"id":"re_1","charge":"ch_rf","payment_intent":"pi_rf","amount":2500,"currency":"inr","status":"succeeded"}}}');
        Test.stopTest();
        Stripe_Payment_Received__c r = [SELECT Status__c, Amount_Received__c, Payment__c FROM Stripe_Payment_Received__c WHERE Event_Id__c = 'evt_rf'];
        System.assertEquals('Refunded', r.Status__c);
        System.assertEquals(-25, r.Amount_Received__c, 'refunds are recorded as a negative amount');
        System.assertEquals(p.Id, r.Payment__c);
    }

    @isTest static void handleWebhook_setupIntentSucceededAndFailed() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Payment__c p = new Stripe_Payment__c(Setup_Intent_Id__c = 'seti_1', Status__c = 'Initiated');
        insert p;
        Test.startTest();
        fireEvent('{"id":"evt_si_ok","type":"setup_intent.succeeded","data":{"object":{"id":"seti_1","status":"succeeded"}}}');
        fireEvent('{"id":"evt_si_bad","type":"setup_intent.setup_failed","data":{"object":{"id":"seti_1","status":"requires_payment_method","cancellation_reason":"abandoned"}}}');
        Test.stopTest();
        System.assertEquals('Succeeded', [SELECT Status__c FROM Stripe_Payment_Received__c WHERE Event_Id__c = 'evt_si_ok'].Status__c);
        System.assertEquals('Failed', [SELECT Status__c FROM Stripe_Payment_Received__c WHERE Event_Id__c = 'evt_si_bad'].Status__c);
    }

    @isTest static void handleWebhook_invoicePaid_newApiParentSubscription_links() {
        StripeTestDataFactory.setupCredentials();
        // Newer Stripe API: no top-level subscription; it's under parent.subscription_details.
        insert new Stripe_Subscription__c(Subscription_Id__c='sub_newapi', Status__c='active', Amount__c=90, Currency__c='inr');
        Test.startTest();
        fireEvent('{"id":"evt_newapi","type":"invoice.paid","data":{"object":{"id":"in_newapi","subscription":null,'
            + '"parent":{"type":"subscription_details","subscription_details":{"subscription":"sub_newapi","metadata":{}}},'
            + '"amount_paid":9000,"currency":"inr"}}}');
        Test.stopTest();
        Stripe_Payment_Received__c r = [SELECT Amount_Received__c, Subscription__c, Subscription_Id__c FROM Stripe_Payment_Received__c WHERE Event_Id__c='evt_newapi'];
        System.assertEquals(90, r.Amount_Received__c);
        System.assertEquals('sub_newapi', r.Subscription_Id__c, 'sub id read from parent.subscription_details');
        System.assertEquals([SELECT Id FROM Stripe_Subscription__c WHERE Subscription_Id__c='sub_newapi'].Id, r.Subscription__c,
            'renewal row linked to the subscription via the new-API parent structure');
    }

    @isTest static void handleWebhook_invoicePaymentSucceeded_noDuplicateRow() {
        StripeTestDataFactory.setupCredentials();
        insert new Stripe_Subscription__c(Subscription_Id__c='sub_dup', Status__c='past_due', Amount__c=50, Currency__c='inr');
        Test.startTest();
        // payment_succeeded is the twin of invoice.paid — it must NOT create a second row.
        fireEvent('{"id":"evt_ps","type":"invoice.payment_succeeded","data":{"object":{"id":"in_ps","subscription":"sub_dup","amount_paid":5000,"currency":"inr"}}}');
        Test.stopTest();
        System.assertEquals('active', [SELECT Status__c FROM Stripe_Subscription__c WHERE Subscription_Id__c='sub_dup'].Status__c);
        System.assertEquals(0, [SELECT COUNT() FROM Stripe_Payment_Received__c WHERE Event_Id__c='evt_ps'], 'no received row from payment_succeeded');
    }

    @isTest static void handleWebhook_invoicePaid_renewal_marksActiveAndLinks() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Subscription__c sub = new Stripe_Subscription__c(Subscription_Id__c = 'sub_ren', Status__c = 'past_due');
        insert sub;
        Stripe_Payment__c p = new Stripe_Payment__c(Subscription_Id__c = 'sub_ren', Status__c = 'Completed');
        insert p;
        Test.startTest();
        fireEvent('{"id":"evt_inv_paid","type":"invoice.paid","data":{"object":{"id":"in_ren","subscription":"sub_ren","amount_paid":5000,"currency":"inr","payment_intent":"pi_ren","charge":"ch_ren"}}}');
        Test.stopTest();
        Stripe_Subscription__c uSub = [SELECT Status__c, Payment__c FROM Stripe_Subscription__c WHERE Subscription_Id__c = 'sub_ren'];
        System.assertEquals('active', uSub.Status__c);
        System.assertEquals(p.Id, uSub.Payment__c, 'subscription linked to its originating payment');
        Stripe_Payment_Received__c r = [SELECT Status__c, Amount_Received__c, Payment__c, Subscription__c FROM Stripe_Payment_Received__c WHERE Event_Id__c = 'evt_inv_paid'];
        System.assertEquals('Succeeded', r.Status__c);
        System.assertEquals(50, r.Amount_Received__c);
        System.assertEquals(p.Id, r.Payment__c, 'renewal is linked to the originating payment');
        System.assertEquals(sub.Id, r.Subscription__c, 'renewal received row is visible on the subscription');
    }

    @isTest static void handleWebhook_invoicePaid_amountFallsBackToTotal() {
        StripeTestDataFactory.setupCredentials();
        insert new Stripe_Subscription__c(Subscription_Id__c = 'sub_oob', Status__c = 'active');
        Stripe_Payment__c p = new Stripe_Payment__c(Subscription_Id__c = 'sub_oob', Status__c = 'Completed');
        insert p;
        Test.startTest();
        // amount_paid=0 (out-of-band) but total=5000 → recorded amount should be 50.
        fireEvent('{"id":"evt_oob","type":"invoice.paid","data":{"object":{"id":"in_oob","subscription":"sub_oob","amount_paid":0,"total":5000,"amount_due":5000,"currency":"inr"}}}');
        Test.stopTest();
        System.assertEquals(50, [SELECT Amount_Received__c FROM Stripe_Payment_Received__c WHERE Event_Id__c = 'evt_oob'].Amount_Received__c);
    }

    @isTest static void handleWebhook_invoiceUncollectibleAndVoided() {
        StripeTestDataFactory.setupCredentials();
        insert new Stripe_Subscription__c(Subscription_Id__c = 'sub_unc', Status__c = 'active');
        Test.startTest();
        fireEvent('{"id":"evt_unc","type":"invoice.marked_uncollectible","data":{"object":{"id":"in_unc","subscription":"sub_unc"}}}');
        Test.stopTest();
        System.assertEquals('unpaid', [SELECT Status__c FROM Stripe_Subscription__c WHERE Subscription_Id__c = 'sub_unc'].Status__c);
    }

    @isTest static void handleWebhook_subscriptionPaused_updates() {
        StripeTestDataFactory.setupCredentials();
        Test.startTest();
        fireEvent('{"id":"evt_sub_p","type":"customer.subscription.updated","data":{"object":{"id":"sub_pd","customer":"cus_1","status":"paused","cancel_at_period_end":true}}}');
        Test.stopTest();
        Stripe_Subscription__c s = [SELECT Status__c, Cancel_At_Period_End__c FROM Stripe_Subscription__c WHERE Subscription_Id__c = 'sub_pd'];
        System.assertEquals('paused', s.Status__c);
        System.assert(s.Cancel_At_Period_End__c);
    }

    @isTest static void handleWebhook_subscriptionDeleted_marksCanceled() {
        StripeTestDataFactory.setupCredentials();
        insert new Stripe_Subscription__c(Subscription_Id__c = 'sub_del', Status__c = 'active');
        Test.startTest();
        fireEvent('{"id":"evt_sub_d","type":"customer.subscription.deleted","data":{"object":{"id":"sub_del","customer":"cus_1","status":"canceled"}}}');
        Test.stopTest();
        System.assertEquals('canceled', [SELECT Status__c FROM Stripe_Subscription__c WHERE Subscription_Id__c = 'sub_del'].Status__c);
    }

    @isTest static void handleWebhook_asyncPaymentFailed_marksFailed() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Payment__c p = new Stripe_Payment__c(Checkout_Session_Id__c = 'cs_async', Status__c = 'Pending', Checkout_Mode__c = 'HOSTED');
        insert p;
        Test.startTest();
        fireEvent('{"id":"evt_async","type":"checkout.session.async_payment_failed","data":{"object":{"id":"cs_async","amount_total":5000,"currency":"inr"}}}');
        Test.stopTest();
        System.assertEquals('Failed', [SELECT Status__c FROM Stripe_Payment__c WHERE Id = :p.Id].Status__c);
        System.assertEquals('Failed', [SELECT Status__c FROM Stripe_Payment_Received__c WHERE Event_Id__c = 'evt_async'].Status__c);
    }

    @isTest static void reprocess_replaysStoredEvent() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Payment__c p = new Stripe_Payment__c(Payment_Intent_Id__c = 'pi_rep', Status__c = 'Initiated');
        insert p;
        Stripe_Webhook_Log__c log = new Stripe_Webhook_Log__c(Event_Id__c = 'evt_rep', Event_Type__c = 'payment_intent.succeeded', Signature_Verified__c = true);
        insert log;
        Test.startTest();
        StripeWebhookHandler.reprocess('{"id":"evt_rep","type":"payment_intent.succeeded","data":{"object":{"id":"pi_rep","status":"succeeded","amount":1000,"currency":"inr"}}}', log.Id);
        Test.stopTest();
        System.assertEquals('Completed', [SELECT Status__c FROM Stripe_Payment__c WHERE Id = :p.Id].Status__c);
        System.assertEquals('Succeeded', [SELECT Status__c FROM Stripe_Payment_Received__c WHERE Event_Id__c = 'evt_rep'].Status__c);
    }

    @isTest static void handleWebhook_subscriptionWithCancelAt_syncsEndDate() {
        StripeTestDataFactory.setupCredentials();
        Test.startTest();
        // Stripe already has cancel_at set (end date) → stored on the record, no queueable.
        fireEvent('{"id":"evt_sub_end","type":"customer.subscription.updated","data":{"object":'
            + '{"id":"sub_end","customer":"cus_1","status":"active","cancel_at":1893456000,"cancel_at_period_end":false,'
            + '"items":{"data":[{"price":{"id":"price_1","product":"prod_1","currency":"inr","unit_amount":5000,"recurring":{"interval":"month"}}}]}}}}');
        Test.stopTest();
        Stripe_Subscription__c s = [SELECT Cancel_At__c, Status__c FROM Stripe_Subscription__c WHERE Subscription_Id__c = 'sub_end'];
        System.assertNotEquals(null, s.Cancel_At__c, 'scheduled end date synced from cancel_at');
    }

    @isTest static void handleWebhook_subscriptionCreatedWithMetaEndDate_schedules() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Long future = (DateTime.now().addMonths(12).getTime()) / 1000;
        Test.startTest();
        // Checkout-created sub carries the end date in metadata; no cancel_at yet →
        // handler should enqueue StripeSubscriptionEndDateQueueable to apply it.
        fireEvent('{"id":"evt_sub_meta","type":"customer.subscription.created","data":{"object":'
            + '{"id":"sub_meta","customer":"cus_1","status":"active","cancel_at":null,'
            + '"metadata":{"sf_sub_cancel_at":"' + future + '"},'
            + '"items":{"data":[{"price":{"id":"price_1","product":"prod_1","currency":"inr","unit_amount":5000,"recurring":{"interval":"month"}}}]}}}}');
        Test.stopTest();
        // Subscription synced and the queueable ran against the mock without error.
        System.assertEquals('Processed', [SELECT Processing_Status__c FROM Stripe_Webhook_Log__c WHERE Event_Id__c = 'evt_sub_meta'].Processing_Status__c);
        System.assertEquals(1, [SELECT COUNT() FROM Stripe_Subscription__c WHERE Subscription_Id__c = 'sub_meta']);
    }

    @isTest static void handleWebhook_staleIncomplete_doesNotRegress() {
        StripeTestDataFactory.setupCredentials();
        insert new Stripe_Subscription__c(Subscription_Id__c='sub_guard', Status__c='active', Amount__c=50, Currency__c='inr');
        Test.startTest();
        // A late 'created/updated' event with status incomplete must NOT overwrite active.
        fireEvent('{"id":"evt_stale","type":"customer.subscription.updated","data":{"object":{"id":"sub_guard","customer":"cus_1","status":"incomplete"}}}');
        Test.stopTest();
        System.assertEquals('active', [SELECT Status__c FROM Stripe_Subscription__c WHERE Subscription_Id__c='sub_guard'].Status__c,
            'stale incomplete event must not regress an active subscription');
    }

    @isTest static void handleWebhook_subSync_backfillsPaymentAndReceived() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Payment__c p = new Stripe_Payment__c(Subscription_Id__c='sub_bf', Status__c='Completed');
        insert p;
        // an orphan received row (created before the subscription existed)
        insert new Stripe_Payment_Received__c(Payment__c=p.Id, Event_Id__c='rcv_orphan', Status__c='Succeeded', Signature_Verified__c=true);
        Test.startTest();
        fireEvent('{"id":"evt_bf","type":"customer.subscription.created","data":{"object":{"id":"sub_bf","customer":"cus_1","status":"active",'
            + '"current_period_start":1700000000,"current_period_end":1702592000,'
            + '"items":{"data":[{"price":{"id":"price_1","product":"prod_1","currency":"inr","unit_amount":5000,"recurring":{"interval":"month"}}}]}}}}');
        Test.stopTest();
        Stripe_Subscription__c s = [SELECT Id, Payment__c, Current_Period_End__c FROM Stripe_Subscription__c WHERE Subscription_Id__c='sub_bf'];
        System.assertEquals(p.Id, s.Payment__c, 'subscription linked to its payment');
        System.assertNotEquals(null, s.Current_Period_End__c, 'period synced');
        System.assertEquals(s.Id, [SELECT Subscription__c FROM Stripe_Payment_Received__c WHERE Event_Id__c='rcv_orphan'].Subscription__c,
            'orphan received row pulled into the subscription');
    }

    @isTest static void handleWebhook_succeeded_doesNotHijackAbandonedOneTime() {
        StripeTestDataFactory.setupCredentials();
        // Donor started one-time (abandoned, still Initiated), switched to recurring which
        // completed via checkout.session.completed. A later payment_intent.succeeded must NOT
        // mark the abandoned one-time as Completed.
        Stripe_Payment__c oneTime = new Stripe_Payment__c(Customer_Id__c='cus_switch', Payment_Type__c='One-Time', Status__c='Initiated');
        insert oneTime;
        Stripe_Payment__c recurring = new Stripe_Payment__c(Customer_Id__c='cus_switch', Payment_Type__c='Recurring', Status__c='Completed');
        insert recurring;
        Test.startTest();
        fireEvent('{"id":"evt_switch","type":"payment_intent.succeeded","data":{"object":{"id":"pi_recinv","customer":"cus_switch","status":"succeeded","amount":5000,"currency":"inr"}}}');
        Test.stopTest();
        System.assertEquals('Initiated', [SELECT Status__c FROM Stripe_Payment__c WHERE Id=:oneTime.Id].Status__c,
            'abandoned one-time payment must stay Initiated');
    }

    @isTest static void handleWebhook_failedByCustomer_linksAndStoresError() {
        StripeTestDataFactory.setupCredentials();
        // Donation/subscription payment: has a customer, no PI id yet, still open.
        Stripe_Payment__c p = new Stripe_Payment__c(Customer_Id__c='cus_fail', Status__c='Initiated', Checkout_Mode__c='EMBEDDED');
        insert p;
        Test.startTest();
        fireEvent('{"id":"evt_custfail","type":"payment_intent.payment_failed","data":{"object":'
            + '{"id":"pi_custfail","customer":"cus_fail","status":"requires_payment_method",'
            + '"last_payment_error":{"message":"Your card was declined."}}}}');
        Test.stopTest();
        Stripe_Payment__c u = [SELECT Status__c, Error_Message__c, Payment_Intent_Id__c FROM Stripe_Payment__c WHERE Id=:p.Id];
        System.assertEquals('Failed', u.Status__c, 'linked via customer id and marked failed');
        System.assertEquals('Your card was declined.', u.Error_Message__c, 'failure reason stored on the payment');
        System.assertEquals('pi_custfail', u.Payment_Intent_Id__c);
        System.assertEquals(p.Id, [SELECT Payment__c FROM Stripe_Payment_Received__c WHERE Event_Id__c='evt_custfail'].Payment__c);
    }

    @isTest static void handleWebhook_subscriptionEvent_syncs() {
        StripeTestDataFactory.setupCredentials();
        String payload = '{"id":"evt_sub_1","type":"customer.subscription.created","data":{"object":'
            + '{"id":"sub_evt_1","customer":"cus_1","status":"active","cancel_at_period_end":false,'
            + '"current_period_start":1700000000,"current_period_end":1702592000,'
            + '"items":{"data":[{"price":{"id":"price_1","product":"prod_1","currency":"usd","unit_amount":1999,"recurring":{"interval":"month"}}}]}}}}';
        Long ts = nowEpoch();
        String header = StripeTestDataFactory.signPayload(payload, StripeTestDataFactory.WEBHOOK_SECRET, ts);

        Test.startTest();
        RestRequest req = new RestRequest();
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(payload);
        req.headers.put('Stripe-Signature', header);
        RestContext.request = req;
        RestContext.response = new RestResponse();
        StripeWebhookHandler.handleWebhook();
        Test.stopTest();

        Stripe_Subscription__c s = [SELECT Status__c, Interval__c, Amount__c FROM Stripe_Subscription__c WHERE Subscription_Id__c = 'sub_evt_1'];
        System.assertEquals('active', s.Status__c);
        System.assertEquals('month', s.Interval__c);
        System.assertEquals(19.99, s.Amount__c);
    }
}