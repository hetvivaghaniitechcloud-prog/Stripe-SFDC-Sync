/**
 * stripeMySubscriptions — Experience Cloud self-service subscription manager.
 *
 * Lists the signed-in user's recurring subscriptions with status and lets them
 * pause / resume / cancel. Every action calls a managed-package @AuraEnabled method
 * (StripeSubscriptionPortalController) which re-checks ownership and updates Stripe;
 * the webhook then syncs the new state back, and we refresh the list.
 */
import { LightningElement, wire, api } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAllSubscriptions from '@salesforce/apex/StripeSubscriptionPortalController.getAllSubscriptions';
import manageSubscription from '@salesforce/apex/StripeSubscriptionService.manageSubscription';

export default class StripeMySubscriptions extends LightningElement {
    @api cardTitle = 'Recurring Subscriptions';

    subs = [];
    loading = true;
    error;
    busySub;
    confirmingSub;
    _wired;

    @wire(getAllSubscriptions)
    wired(result) {
        this._wired = result;
        this.loading = false;
        if (result.data) { this.subs = this.decorate(result.data); this.error = undefined; }
        else if (result.error) { this.error = this.msg(result.error); }
    }

    get hasSubs() { return this.subs && this.subs.length > 0; }
    get isEmpty() { return !this.loading && !this.error && !this.hasSubs; }

    decorate(list) {
        return list.map((s) => {
            const active = s.statusKey === 'active';
            return {
                ...s,
                amountLabel: this.money(s.amount, s.currencyCode) + (s.interval ? ' / ' + s.interval : ''),
                badgeClass: 'badge badge_' + s.statusKey,
                subLine: active && s.nextRenewal
                    ? 'Next payment: ' + this.date(s.nextRenewal)
                    : (s.cancelAt ? 'Scheduled to end: ' + this.date(s.cancelAt)
                        : (s.endedAt ? 'Ended: ' + this.date(s.endedAt) : '')),
                busy: s.subscriptionId === this.busySub,
                confirming: s.subscriptionId === this.confirmingSub
            };
        });
    }

    money(a, c) {
        try {
            return new Intl.NumberFormat(undefined, { style: 'currency', currency: (c || 'usd').toUpperCase() }).format(a || 0);
        } catch (e) {
            return (a || 0) + ' ' + (c || '').toUpperCase();
        }
    }
    date(d) { try { return new Date(d).toLocaleDateString(); } catch (e) { return ''; } }

    async act(action, subId, okMsg) {
        this.busySub = subId;
        this.confirmingSub = null;
        this.subs = this.decorate(this.subs);
        try {
            const res = JSON.parse(await manageSubscription({ subscriptionId: subId, action }));
            if (!res.success) throw new Error(res.message || 'Action could not be completed.');
            this.toast('Success', okMsg, 'success');
            await refreshApex(this._wired);
        } catch (e) {
            this.toast('Error', this.msg(e), 'error');
        } finally {
            this.busySub = null;
            this.subs = this.decorate(this.subs);
        }
    }

    handlePause(e) { this.act('pause', e.target.dataset.sub, 'Subscription paused.'); }
    handleResume(e) { this.act('resume', e.target.dataset.sub, 'Subscription resumed.'); }
    askCancel(e) { this.confirmingSub = e.target.dataset.sub; this.subs = this.decorate(this.subs); }
    keepIt() { this.confirmingSub = null; this.subs = this.decorate(this.subs); }
    confirmCancel(e) { this.act('cancel', e.target.dataset.sub, 'Subscription cancelled.'); }

    refresh() { this.loading = true; refreshApex(this._wired).finally(() => { this.loading = false; }); }

    msg(e) {
        if (!e) return 'Something went wrong.';
        if (e.body && e.body.message) return e.body.message;
        return e.message || 'Something went wrong.';
    }
    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}