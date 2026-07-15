/**
 * StripeWebhookRetry — replays Stripe_Webhook_Log__c entries that were
 * signature-verified but failed during processing (Processing_Status__c = 'Error').
 * Unverified events are NOT retried (the original signature header is not stored,
 * so they can never be re-verified — by design).
 *
 * Run on demand from the Webhooks admin tab, or schedule via Schedulable.
 */
public with sharing class StripeWebhookRetry implements Schedulable {

    public void execute(SchedulableContext ctx) { retryFailed(50); }

    @AuraEnabled
    public static String retryFailedLWC() {
        try {
            Integer n = retryFailed(50);
            return JSON.serialize(new Map<String, Object>{ 'success' => true, 'retried' => n });
        } catch (Exception e) {
            return JSON.serialize(new Map<String, Object>{ 'success' => false, 'message' => e.getMessage() });
        }
    }

    public static Integer retryFailed(Integer maxRecords) {
        List<Stripe_Webhook_Log__c> failed = [
            SELECT Id, Payload__c, Event_Type__c
            FROM Stripe_Webhook_Log__c
            WHERE Processing_Status__c = 'Error' AND Signature_Verified__c = true
            ORDER BY CreatedDate ASC
            LIMIT :maxRecords
        ];
        List<Stripe_Webhook_Log__c> toUpdate = new List<Stripe_Webhook_Log__c>();
        for (Stripe_Webhook_Log__c log : failed) {
            try {
                if (String.isBlank(log.Payload__c)) continue;
                StripeWebhookHandler.reprocess(log.Payload__c, log.Id);
                log.Processing_Status__c = 'Processed';
                log.Error_Message__c = null;
            } catch (Exception e) {
                log.Error_Message__c = 'Retry failed: ' + e.getMessage();
            }
            toUpdate.add(log);
        }
        if (!toUpdate.isEmpty()) update toUpdate;
        return toUpdate.size();
    }
}