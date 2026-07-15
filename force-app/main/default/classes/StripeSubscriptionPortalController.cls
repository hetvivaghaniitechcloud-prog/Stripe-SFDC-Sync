/**
 * StripeSubscriptionPortalController — self-service subscription management for
 * Experience Cloud (community) users.
 *
 * A logged-in community user sees ONLY their own recurring subscriptions (matched on
 * their Contact) and can pause / resume / cancel them. Every action re-verifies that
 * the target subscription belongs to the running user's Contact before calling Stripe,
 * so one user can never touch another's subscription.
 *
 * Runs `without sharing` on purpose: these package records are created by the webhook
 * (system-owned) and are not shared to the donor, so we scope access ourselves by the
 * running user's Contact id (which comes from UserInfo and cannot be spoofed).
 */
public without sharing class StripeSubscriptionPortalController {

    public class SubInfo {
        @AuraEnabled public String id;              // Stripe_Subscription__c record id
        @AuraEnabled public String subscriptionId;  // Stripe sub_...
        @AuraEnabled public Decimal amount;
        @AuraEnabled public String currencyCode;
        @AuraEnabled public String interval;         // month | year
        @AuraEnabled public String statusKey;        // active | paused | cancelled | other
        @AuraEnabled public String statusLabel;
        @AuraEnabled public Boolean canPause;
        @AuraEnabled public Boolean canResume;
        @AuraEnabled public Boolean canCancel;
        @AuraEnabled public Datetime nextRenewal;
        @AuraEnabled public Datetime cancelAt;
        @AuraEnabled public Datetime endedAt;
    }

    /**
     * TEST/DEMO: return every subscription (no identity filter) so a guest test site can
     * exercise pause/cancel/resume. In production the subscriber org filters by whatever
     * identity model they use (Contact, email, external id) — see getMySubscriptions.
     */
    @AuraEnabled(cacheable=true)
    public static List<SubInfo> getAllSubscriptions() {
        List<SubInfo> out = new List<SubInfo>();
        for (Stripe_Subscription__c s : [
            SELECT Id, Subscription_Id__c, Status__c, Paused__c, Amount__c, Currency__c, Interval__c,
                   Current_Period_End__c, Cancel_At__c, Ended_At__c
            FROM Stripe_Subscription__c
            WHERE Subscription_Id__c != null
            ORDER BY CreatedDate DESC LIMIT 200
        ]) out.add(toInfo(s));
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static List<SubInfo> getMySubscriptions() {
        Id contactId = runningUserContactId();
        if (contactId == null) return new List<SubInfo>();
        List<Stripe_Subscription__c> subs = [
            SELECT Id, Subscription_Id__c, Status__c, Paused__c, Amount__c, Currency__c, Interval__c,
                   Current_Period_End__c, Cancel_At__c, Ended_At__c
            FROM Stripe_Subscription__c
            WHERE Source_Record_Id__c = :String.valueOf(contactId)
            ORDER BY CreatedDate DESC
            LIMIT 200
        ];
        List<SubInfo> out = new List<SubInfo>();
        for (Stripe_Subscription__c s : subs) out.add(toInfo(s));
        return out;
    }

    @AuraEnabled
    public static String cancelMySubscription(Id recordId) {
        Stripe_Subscription__c s = ownedOrThrow(recordId);
        return StripeSubscriptionService.cancelSubscription(s.Subscription_Id__c, false);
    }

    @AuraEnabled
    public static String pauseMySubscription(Id recordId) {
        Stripe_Subscription__c s = ownedOrThrow(recordId);
        return StripeSubscriptionService.pauseSubscription(s.Subscription_Id__c);
    }

    @AuraEnabled
    public static String resumeMySubscription(Id recordId) {
        Stripe_Subscription__c s = ownedOrThrow(recordId);
        return StripeSubscriptionService.resumeSubscription(s.Subscription_Id__c);
    }

    // ── helpers ──

    private static Id runningUserContactId() {
        List<User> us = [SELECT ContactId FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        return (!us.isEmpty()) ? us[0].ContactId : null;
    }

    /** Load the subscription and confirm it belongs to the running user's Contact. */
    private static Stripe_Subscription__c ownedOrThrow(Id recordId) {
        Id contactId = runningUserContactId();
        if (contactId == null) throw new AuraHandledException('You must be signed in to manage subscriptions.');
        List<Stripe_Subscription__c> subs = [
            SELECT Id, Subscription_Id__c, Source_Record_Id__c
            FROM Stripe_Subscription__c WHERE Id = :recordId LIMIT 1
        ];
        if (subs.isEmpty() || subs[0].Source_Record_Id__c != String.valueOf(contactId)) {
            throw new AuraHandledException('Subscription not found for your account.');
        }
        if (String.isBlank(subs[0].Subscription_Id__c)) {
            throw new AuraHandledException('This subscription has no Stripe id.');
        }
        return subs[0];
    }

    @TestVisible
    private static SubInfo toInfo(Stripe_Subscription__c s) {
        SubInfo i = new SubInfo();
        i.id = s.Id;
        i.subscriptionId = s.Subscription_Id__c;
        i.amount = s.Amount__c;
        i.currencyCode = s.Currency__c;
        i.interval = s.Interval__c;
        i.nextRenewal = s.Current_Period_End__c;
        i.cancelAt = s.Cancel_At__c;
        i.endedAt = s.Ended_At__c;

        Boolean cancelled = (s.Status__c == 'canceled') || (s.Status__c == 'incomplete_expired') || (s.Ended_At__c != null);
        Boolean paused = (s.Paused__c == true) && !cancelled;
        Boolean active = !cancelled && !paused
            && (s.Status__c == 'active' || s.Status__c == 'trialing' || s.Status__c == 'past_due' || s.Status__c == 'unpaid');

        if (cancelled) { i.statusKey = 'cancelled'; i.statusLabel = 'Cancelled'; }
        else if (paused) { i.statusKey = 'paused'; i.statusLabel = 'Paused'; }
        else if (active) { i.statusKey = 'active'; i.statusLabel = 'Active'; }
        else { i.statusKey = 'other'; i.statusLabel = (s.Status__c == null ? 'Unknown' : s.Status__c); }

        i.canCancel = !cancelled;
        i.canPause = active;
        i.canResume = paused;
        return i;
    }
}