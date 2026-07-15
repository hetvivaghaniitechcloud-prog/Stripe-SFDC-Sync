/**
 * stripePaymentPopup — Easebuzz-style payment modal.
 *
 * Renders a centered overlay (dim backdrop) containing an <iframe> to a static
 * resource page that runs Stripe Embedded Checkout. Because the iframe is a
 * separate browsing context, Stripe.js runs OUTSIDE Lightning Web Security, so
 * the full payment (method selection, submit, 3DS) works inside an LWR community.
 *
 * Stripe Embedded Checkout shows every payment method enabled in your Stripe
 * Dashboard for the session's amount/currency/device (card, UPI, wallets, etc).
 *
 * Communicates with the iframe via postMessage:
 *   stripe_ready    → hide spinner
 *   stripe_complete → emit 'complete'
 *   stripe_error    → show error
 */
import { LightningElement, api } from 'lwc';
import STRIPE_FRAME from '@salesforce/resourceUrl/stripeCheckoutFrame';

export default class StripePaymentPopup extends LightningElement {
    @api publishableKey;
    @api clientSecret;
    @api amountLabel;
    @api returnUrl;
    @api headerTitle = 'Secure Payment';
    @api inline = false;   // true → render in-page (no overlay/backdrop)

    get modalClass() { return this.inline ? 'sp-modal sp-inline' : 'sp-modal'; }
    get showBackdrop() { return !this.inline; }
    get showCancel() { return !this.inline; }   // inline has its own "Change details" control
    get showHeader() { return !this.inline; }   // inline: Stripe's own iframe header is enough

    loading = true;
    error;
    _handler;

    connectedCallback() {
        this._handler = this.onMessage.bind(this);
        window.addEventListener('message', this._handler);
    }
    disconnectedCallback() {
        if (this._handler) window.removeEventListener('message', this._handler);
    }

    onMessage(event) {
        const data = event && event.data;
        if (!data || typeof data !== 'object') return;
        switch (data.type) {
            case 'stripe_ready':
                this.loading = false;
                break;
            case 'stripe_height':
                this.setFrameHeight(data.height);
                break;
            case 'stripe_complete':
                this.dispatchEvent(new CustomEvent('complete', { bubbles: true, composed: true }));
                break;
            case 'stripe_error':
                this.loading = false;
                this.error = data.message || 'Payment could not be loaded.';
                this.dispatchEvent(new CustomEvent('failure', { detail: { message: this.error }, bubbles: true, composed: true }));
                break;
            default:
                break;
        }
    }

    get iframeUrl() {
        if (!this.publishableKey || !this.clientSecret) return 'about:blank';
        const ret = this.returnUrl || window.location.href;
        return STRIPE_FRAME + '/index.html'
            + '#pk=' + encodeURIComponent(this.publishableKey)
            + '&cs=' + encodeURIComponent(this.clientSecret)
            + '&ret=' + encodeURIComponent(ret);
    }

    setFrameHeight(h) {
        const frame = this.template.querySelector('.sp-frame');
        if (frame && h && h > 0) frame.style.height = h + 'px';
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('close', { bubbles: true, composed: true }));
    }
}