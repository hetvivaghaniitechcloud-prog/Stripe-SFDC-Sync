/**
 * stripeSubscriptionForm — recurring/subscription checkout.
 *
 * Reads the Stripe_Payment_Config__c (Payment_Type=Recurring) for the object to
 * get the Price Id, trial days, currency and checkout mode, then drives:
 *   HOSTED / EMBEDDED → Checkout Session (mode=subscription)
 *   CUSTOM            → find/create Customer + Subscriptions API (default_incomplete)
 *                       then confirm the client_secret in the Payment Element.
 */
import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import getConfigWithRecordValues from '@salesforce/apex/StripeConfigReader.getConfigWithRecordValues';
import getCredentialsInfo from '@salesforce/apex/StripeConfigReader.getCredentialsInfo';
import createSubscriptionCheckout from '@salesforce/apex/StripeSubscriptionService.createSubscriptionCheckout';
import createSubscription from '@salesforce/apex/StripeSubscriptionService.createSubscription';
import findOrCreateCustomer from '@salesforce/apex/StripeCustomerService.findOrCreateCustomerLWC';

export default class StripeSubscriptionForm extends LightningElement {
    @api recordId;
    @api objectApiName;
    @api configName;

    @track stage = 'loading'; // loading | form | embedded | element | done | error
    @track errorMessage;

    config;
    publishableKey;
    clientSecret;
    customerEmail;
    customerName;
    checkoutMode = 'HOSTED';

    connectedCallback() {
        this.init();
    }

    async init() {
        try {
            const cred = JSON.parse(await getCredentialsInfo());
            if (!cred.isConfigured) throw new Error('Stripe is not configured.');
            this.publishableKey = cred.publishableKey;

            const res = JSON.parse(await getConfigWithRecordValues({
                recordId: this.recordId, objectApiName: this.objectApiName, configName: this.configName
            }));
            if (!res.success) throw new Error(res.message || 'No recurring config found.');
            this.config = res.config;
            if (this.config.paymentType !== 'Recurring' || !this.config.priceId) {
                throw new Error('This configuration is not set up for recurring billing (needs Payment Type = Recurring and a Price Id).');
            }
            this.checkoutMode = (this.config.checkoutMode || 'HOSTED').toUpperCase();
            this.customerEmail = res.fieldValues ? res.fieldValues.Email_Field : null;
            this.customerName = res.fieldValues ? res.fieldValues.Name_Field : null;
            this.stage = 'form';
        } catch (e) {
            this.errorMessage = this.msg(e);
            this.stage = 'error';
        }
    }

    handleEmailChange(e) { this.customerEmail = e.target.value; }

    async handleSubscribe() {
        this.errorMessage = undefined;
        this.stage = 'loading';
        try {
            if (this.checkoutMode === 'CUSTOM') {
                await this.subscribeCustom();
            } else {
                await this.subscribeCheckout();
            }
        } catch (e) {
            this.errorMessage = this.msg(e);
            this.stage = 'error';
        }
    }

    async subscribeCheckout() {
        const res = JSON.parse(await createSubscriptionCheckout({
            priceId: this.config.priceId,
            mode: this.checkoutMode,
            customerEmail: this.customerEmail,
            customerId: null,
            trialDays: this.config.trialDays,
            allowPromotionCodes: this.config.allowPromotionCodes,
            sfRecordId: this.recordId,
            endDate: this.config.endDate || null
        }));
        if (!res.success) throw new Error(res.message || 'Failed to start subscription.');
        this.publishableKey = res.publishableKey || this.publishableKey;
        if (this.checkoutMode === 'EMBEDDED') {
            this.clientSecret = res.clientSecret;
            this.stage = 'embedded';
        } else if (res.hostedUrl) {
            window.open(res.hostedUrl, '_self');
            this.stage = 'done';
        } else {
            throw new Error('No checkout URL returned.');
        }
    }

    async subscribeCustom() {
        const cust = JSON.parse(await findOrCreateCustomer({
            email: this.customerEmail, name: this.customerName, sfRecordId: this.recordId
        }));
        if (!cust.success || !cust.customerId) throw new Error(cust.message || 'Could not create customer.');
        const res = JSON.parse(await createSubscription({
            customerId: cust.customerId, priceId: this.config.priceId,
            trialDays: this.config.trialDays, sfObject: this.objectApiName, sfRecordId: this.recordId,
            endDate: this.config.endDate || null
        }));
        if (!res.success) throw new Error(res.message || 'Failed to create subscription.');
        this.clientSecret = res.clientSecret;
        if (!this.clientSecret) {
            // Trial with no immediate payment — nothing to confirm.
            this.toast('Subscribed', 'Subscription created.', 'success');
            this.stage = 'done';
            return;
        }
        this.stage = 'element';
    }

    handleChildSuccess() {
        this.toast('Subscribed', 'Your subscription is active.', 'success');
        this.stage = 'done';
        this.close();
    }
    handleChildFailure(e) { this.errorMessage = (e.detail && e.detail.message) || 'Payment failed.'; this.stage = 'error'; }
    handleChildClose() { this.close(); }
    handleClose() { this.close(); }

    close() {
        this.dispatchEvent(new CloseActionScreenEvent());
        this.dispatchEvent(new CustomEvent('close', { bubbles: true, composed: true }));
    }

    get planSummary() {
        if (!this.config) return '';
        const trial = this.config.trialDays ? ` (after a ${this.config.trialDays}-day trial)` : '';
        return `Recurring plan ${this.config.priceId}${trial}`;
    }
    get isLoading() { return this.stage === 'loading'; }
    get showForm() { return this.stage === 'form'; }
    get showEmbedded() { return this.stage === 'embedded'; }
    get showElement() { return this.stage === 'element'; }
    get showError() { return this.stage === 'error'; }
    get returnUrl() { return window.location.href; }

    toast(t, m, v) { this.dispatchEvent(new ShowToastEvent({ title: t, message: m, variant: v })); }
    msg(e) { return e && e.body && e.body.message ? e.body.message : (e && e.message ? e.message : 'Unexpected error'); }
}