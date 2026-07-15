/**
 * stripeReturn — lightweight confirmation page for redirect-based flows.
 * Reads the session_id / payment_intent from the URL and shows status. Keyed on
 * the Stripe id (NOT a Salesforce record), so it works for guest users too.
 */
import { LightningElement, track } from 'lwc';

export default class StripeReturn extends LightningElement {
    @track sessionId;
    @track paymentIntent;

    connectedCallback() {
        const params = new URLSearchParams(window.location.search);
        this.sessionId = params.get('session_id');
        this.paymentIntent = params.get('payment_intent');
    }

    get hasReference() {
        return !!(this.sessionId || this.paymentIntent);
    }
}