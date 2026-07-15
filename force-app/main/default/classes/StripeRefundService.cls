/**
 * StripeRefundService — issue and look up refunds, syncing Stripe_Payment__c.
 * Amounts are in major units in Salesforce; Stripe expects the smallest unit.
 */
public with sharing class StripeRefundService {

    @AuraEnabled
    public static String createRefund(Id paymentRecordId, Decimal amount, String reason) {
        try {
            // Internal package object — trusted refund bookkeeping in system mode.
            List<Stripe_Payment__c> pays = [
                SELECT Id, Payment_Intent_Id__c, Charge_Id__c, Amount__c, Refunded_Amount__c, Currency__c
                FROM Stripe_Payment__c WHERE Id = :paymentRecordId LIMIT 1
            ];
            if (pays.isEmpty()) return fail('Payment record not found.');
            Stripe_Payment__c p = pays[0];
            if (String.isBlank(p.Payment_Intent_Id__c) && String.isBlank(p.Charge_Id__c)) {
                return fail('No PaymentIntent or Charge on this payment to refund.');
            }

            Map<String, Object> body = new Map<String, Object>();
            if (String.isNotBlank(p.Payment_Intent_Id__c)) body.put('payment_intent', p.Payment_Intent_Id__c);
            else body.put('charge', p.Charge_Id__c);
            if (amount != null && amount > 0) body.put('amount', (amount * 100).setScale(0, System.RoundingMode.HALF_UP).longValue());
            if (String.isNotBlank(reason)) body.put('reason', reason);

            String idem = 'refund_' + paymentRecordId + '_' + DateTime.now().getTime();
            StripeApiService.ApiResponse r = StripeApiService.callout('REFUND_CREATE', body, idem);
            if (!r.success) return fail(r.errorMessage);

            Decimal refundedNow = (amount != null && amount > 0) ? amount : p.Amount__c;
            Decimal prior = p.Refunded_Amount__c != null ? p.Refunded_Amount__c : 0;
            p.Refunded_Amount__c = prior + refundedNow;
            p.Status__c = (p.Amount__c != null && p.Refunded_Amount__c >= p.Amount__c) ? 'Refunded' : 'Partial Refunded';
            if (Schema.sObjectType.Stripe_Payment__c.isUpdateable()) update p;

            // Record the refund API response in the received trail (raw response stored).
            recordRefundReceived(p, r, refundedNow);

            return JSON.serialize(new Map<String, Object>{
                'success' => true, 'refundId' => r.stripeId, 'status' => p.Status__c
            });
        } catch (Exception e) { return fail(e.getMessage()); }
    }

    @AuraEnabled
    public static String getRefund(String refundId) {
        try {
            StripeApiService.ApiResponse r = StripeApiService.callout('REFUND_GET',
                new Map<String, String>{ 'id' => refundId }, null, null);
            return JSON.serialize(new Map<String, Object>{
                'success' => r.success, 'body' => r.rawBody, 'message' => r.errorMessage
            });
        } catch (Exception e) { return fail(e.getMessage()); }
    }

    /** Persist the refund API response as a Stripe_Payment_Received__c row (with raw response). */
    private static void recordRefundReceived(Stripe_Payment__c p, StripeApiService.ApiResponse r, Decimal refundedNow) {
        try {
            String refundStatus = (r.data != null) ? String.valueOf(r.data.get('status')) : null;
            String status = (refundStatus == 'failed') ? 'Failed' : (refundStatus == 'pending' ? 'Pending' : 'Refunded');
            String raw = r.rawBody;
            Stripe_Payment_Received__c rec = new Stripe_Payment_Received__c(
                Payment__c = p.Id,
                Event_Id__c = 'api_refund_' + (r.stripeId != null ? r.stripeId : String.valueOf(DateTime.now().getTime())),
                Event_Type__c = 'refund.api',
                Status__c = status,
                Amount_Received__c = refundedNow != null ? (refundedNow * -1) : null,
                Currency__c = p.Currency__c,
                Payment_Intent_Id__c = p.Payment_Intent_Id__c,
                Charge_Id__c = p.Charge_Id__c,
                Signature_Verified__c = false,
                Received_Date__c = System.now(),
                Raw_Payload__c = (raw != null) ? (raw.length() > 131072 ? raw.left(131072) : raw) : null
            );
            if (Schema.sObjectType.Stripe_Payment_Received__c.isCreateable()) insert rec;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'recordRefundReceived failed: ' + e.getMessage());
        }
    }

    private static String fail(String m) { return JSON.serialize(new Map<String, Object>{ 'success' => false, 'message' => m }); }
}