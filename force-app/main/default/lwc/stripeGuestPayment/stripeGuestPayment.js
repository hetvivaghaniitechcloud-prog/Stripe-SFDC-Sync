/**
 * stripeGuestPayment — SAMPLE public/guest payment page.
 *
 * Designed for an Experience Cloud (guest) site. Collects only minimal customer
 * fields and a config name; the amount/price is resolved SERVER-SIDE by
 * StripePaymentEngine.createGuestCheckoutSession (the client can never set it).
 * Only the client_secret / hosted url + publishable key come back.
 *
 * Deployable targets here are AppPage/HomePage so it installs in any org. To use
 * it on a public community page, enable Digital Experiences and add
 * lightning__CommunityPage + lightningCommunity__Default to the targets.
 */
import { LightningElement, api, track } from 'lwc';
import createGuestCheckoutSession from '@salesforce/apex/StripePaymentEngine.createGuestCheckoutSession';

export default class StripeGuestPayment extends LightningElement {
    @api configName;       // the Guest_Enabled Stripe_Payment_Config__c name
    @api heading = 'Complete your payment';

    @track name;
    @track email;
    @track phone;
    @track stage = 'form'; // form | loading | embedded | done | error
    @track errorMessage;

    publishableKey;
    clientSecret;

    handleChange(e) { this[e.target.dataset.field] = e.target.value; }

    async handlePay() {
        this.errorMessage = undefined;
        if (!this.email) { this.errorMessage = 'Please enter your email.'; return; }
        if (!this.configName) { this.errorMessage = 'This page is not configured (missing config name).'; return; }
        this.stage = 'loading';
        try {
            const res = JSON.parse(await createGuestCheckoutSession({
                configName: this.configName,
                customerName: this.name,
                customerEmail: this.email,
                customerPhone: this.phone
            }));
            if (!res.success) throw new Error(res.message || 'Could not start checkout.');
            this.publishableKey = res.publishableKey;
            if (res.clientSecret) {
                this.clientSecret = res.clientSecret;
                this.stage = 'embedded';
            } else if (res.hostedUrl) {
                window.open(res.hostedUrl, '_self');
                this.stage = 'done';
            } else {
                throw new Error('No checkout returned.');
            }
        } catch (e) {
            this.errorMessage = e && e.message ? e.message : 'Payment could not be started.';
            this.stage = 'error';
        }
    }

    handleReset() { this.stage = 'form'; this.errorMessage = undefined; }

    get showForm() { return this.stage === 'form'; }
    get isLoading() { return this.stage === 'loading'; }
    get showEmbedded() { return this.stage === 'embedded'; }
    get showError() { return this.stage === 'error'; }
}