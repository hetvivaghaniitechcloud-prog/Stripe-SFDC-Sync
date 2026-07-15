/**
 * stripePaymentElement — CUSTOM mode. Renders the Stripe Payment Element fully
 * inside our own LWC UI (no redirect) against a PaymentIntent / SetupIntent /
 * Subscription client_secret, and confirms with stripe.confirmPayment.
 *
 * A return_url is still required because some methods (3DS, bank redirects)
 * redirect; pass a lightweight confirmation page URL.
 *
 * Emits `composed` events: 'success', 'failure', 'close'.
 */
import { LightningElement, api } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';

const STRIPE_JS = 'https://js.stripe.com/v3/';

export default class StripePaymentElement extends LightningElement {
    @api publishableKey;
    @api clientSecret;
    @api returnUrl;
    @api amountLabel;

    error;
    loading = true;
    processing = false;
    _mounted = false;
    stripe;
    elements;

    renderedCallback() {
        if (this._mounted) return;
        this._mounted = true;
        this.init();
    }

    async init() {
        try {
            if (!window.Stripe) {
                await loadScript(this, STRIPE_JS);
            }
            if (!this.publishableKey || !this.clientSecret) {
                throw new Error('Missing publishable key or client secret.');
            }
            this.stripe = window.Stripe(this.publishableKey);
            this.elements = this.stripe.elements({ clientSecret: this.clientSecret });
            const paymentElement = this.elements.create('payment');
            paymentElement.mount(this.template.querySelector('.stripe-payment-element'));
            this.loading = false;
        } catch (e) {
            this.loading = false;
            this.error = e && e.message ? e.message : 'Failed to load Stripe Payment Element.';
        }
    }

    async handlePay() {
        this.error = undefined;
        this.processing = true;
        try {
            const result = await this.stripe.confirmPayment({
                elements: this.elements,
                confirmParams: {
                    return_url: this.returnUrl || window.location.href
                },
                redirect: 'if_required'
            });
            this.processing = false;
            if (result.error) {
                this.error = result.error.message;
                this.dispatchEvent(new CustomEvent('failure', {
                    detail: { message: result.error.message },
                    bubbles: true, composed: true
                }));
            } else {
                this.dispatchEvent(new CustomEvent('success', {
                    detail: { paymentIntent: result.paymentIntent },
                    bubbles: true, composed: true
                }));
            }
        } catch (e) {
            this.processing = false;
            this.error = e && e.message ? e.message : 'Payment confirmation failed.';
        }
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close', { bubbles: true, composed: true }));
    }

    get payDisabled() {
        return this.loading || this.processing;
    }
}