/**
 * stripeCheckoutEmbedded — mounts Stripe Embedded Checkout in-page (no redirect).
 *
 * Driven by a Checkout Session created with ui_mode=embedded; the server returns
 * its client_secret. We load Stripe.js from js.stripe.com (it self-updates and
 * refuses to run if self-hosted), then stripe.initEmbeddedCheckout({clientSecret})
 * and mount it into our container.
 *
 * Emits a `composed` 'close' event so a parent quick-action wrapper can fire
 * CloseActionScreenEvent (the critical UX pattern preserved from Easebuzz).
 */
import { LightningElement, api } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';

const STRIPE_JS = 'https://js.stripe.com/v3/';

export default class StripeCheckoutEmbedded extends LightningElement {
    @api publishableKey;
    @api clientSecret;

    error;
    loading = true;
    _mounted = false;
    checkout;

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
            const stripe = window.Stripe(this.publishableKey);
            this.checkout = await stripe.initEmbeddedCheckout({
                clientSecret: this.clientSecret,
                // Fires when the payment completes in-page (session created with
                // redirect_on_completion: 'never') — the user never leaves Salesforce.
                onComplete: () => {
                    this.dispatchEvent(new CustomEvent('complete', { bubbles: true, composed: true }));
                }
            });
            const container = this.template.querySelector('.stripe-embedded-container');
            this.checkout.mount(container);
            this.loading = false;
        } catch (e) {
            this.loading = false;
            this.error = e && e.message ? e.message : 'Failed to load Stripe Embedded Checkout.';
        }
    }

    disconnectedCallback() {
        try { if (this.checkout) this.checkout.destroy(); } catch (e) { /* noop */ }
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close', { bubbles: true, composed: true }));
    }
}