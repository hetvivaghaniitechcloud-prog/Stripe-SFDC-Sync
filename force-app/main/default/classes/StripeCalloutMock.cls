/**
 * StripeCalloutMock — HttpCalloutMock returning canned Stripe JSON per endpoint.
 * Routes on the request endpoint path so one mock covers every operation.
 */
@isTest
public class StripeCalloutMock implements HttpCalloutMock {

    public Integer statusCode = 200;
    public Boolean forceError = false;

    public StripeCalloutMock() {}
    public StripeCalloutMock(Integer status, Boolean error) { this.statusCode = status; this.forceError = error; }

    public HTTPResponse respond(HTTPRequest req) {
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');
        String url = req.getEndpoint();
        String body;

        if (forceError) {
            res.setStatusCode(402);
            res.setBody('{"error":{"message":"Your card was declined.","type":"card_error","code":"card_declined"}}');
            return res;
        }

        if (url.contains('/checkout/sessions')) {
            body = '{"id":"cs_test_123","object":"checkout.session","url":"https://checkout.stripe.com/c/pay/cs_test_123","client_secret":"cs_test_123_secret","payment_status":"unpaid","status":"open"}';
        } else if (url.contains('/payment_intents')) {
            body = '{"id":"pi_test_123","object":"payment_intent","client_secret":"pi_test_123_secret_abc","status":"requires_payment_method"}';
        } else if (url.contains('/setup_intents')) {
            body = '{"id":"seti_test_123","object":"setup_intent","client_secret":"seti_test_123_secret","status":"requires_payment_method"}';
        } else if (url.contains('/customers/search')) {
            body = '{"object":"search_result","data":[{"id":"cus_test_123","email":"a@b.com"}],"has_more":false}';
        } else if (url.contains('/customers')) {
            body = '{"id":"cus_test_123","object":"customer","email":"a@b.com"}';
        } else if (url.contains('/subscriptions')) {
            body = '{"id":"sub_test_123","object":"subscription","status":"active","latest_invoice":{"id":"in_1","payment_intent":{"id":"pi_sub_1","client_secret":"pi_sub_1_secret"}},"items":{"data":[{"price":{"id":"price_1","product":"prod_1","currency":"usd","unit_amount":1999,"recurring":{"interval":"month"}}}]}}';
        } else if (url.contains('/prices')) {
            body = '{"id":"price_test_123","object":"price","unit_amount":1999,"currency":"usd"}';
        } else if (url.contains('/products')) {
            body = '{"id":"prod_test_123","object":"product","name":"Test"}';
        } else if (url.contains('/refunds')) {
            body = '{"id":"re_test_123","object":"refund","status":"succeeded","amount":1999}';
        } else if (url.contains('/billing_portal/sessions')) {
            body = '{"id":"bps_test_123","object":"billing_portal.session","url":"https://billing.stripe.com/p/session/test_123"}';
        } else if (url.contains('/webhook_endpoints')) {
            body = '{"id":"we_test_123","object":"webhook_endpoint","secret":"whsec_test_registered","url":"https://x/services/apexrest/stripe/webhook"}';
        } else if (url.contains('/account')) {
            body = '{"id":"acct_test_123","object":"account","country":"IN","default_currency":"inr"}';
        } else if (url.contains('/payment_links')) {
            body = '{"id":"plink_test_123","object":"payment_link","url":"https://buy.stripe.com/test_123"}';
        } else {
            body = '{"id":"obj_test_123","object":"unknown"}';
        }

        res.setStatusCode(statusCode);
        res.setBody(body);
        return res;
    }
}