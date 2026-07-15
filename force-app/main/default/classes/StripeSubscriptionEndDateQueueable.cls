/**
 * StripeSubscriptionEndDateQueueable — applies a scheduled end date (cancel_at) to a
 * subscription that was created via Checkout.
 *
 * Why a Queueable: Checkout's subscription_data does NOT accept cancel_at, so the end
 * date is carried in subscription metadata (sf_sub_cancel_at = unix epoch) and applied
 * as a follow-up SUBSCRIPTION_UPDATE. The webhook that first sees the subscription runs
 * in a DML context, and a synchronous callout after DML is not allowed — so we enqueue
 * this job, which makes the callout in its own fresh transaction and re-syncs the record.
 */
public without sharing class StripeSubscriptionEndDateQueueable implements Queueable, Database.AllowsCallouts {

    private final String subscriptionId;
    private final Long cancelAtEpoch;

    public StripeSubscriptionEndDateQueueable(String subscriptionId, Long cancelAtEpoch) {
        this.subscriptionId = subscriptionId;
        this.cancelAtEpoch = cancelAtEpoch;
    }

    public void execute(QueueableContext ctx) {
        if (String.isBlank(subscriptionId) || cancelAtEpoch == null) return;
        try {
            StripeApiService.ApiResponse r = StripeApiService.callout(
                'SUBSCRIPTION_UPDATE',
                new Map<String, String>{ 'id' => subscriptionId },
                new Map<String, Object>{ 'cancel_at' => cancelAtEpoch },
                null);
            if (r.success && r.data != null) {
                StripeSubscriptionService.syncFromData(r.data, null, null, r.rawBody);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Apply end date failed for ' + subscriptionId + ': ' + e.getMessage());
        }
    }
}