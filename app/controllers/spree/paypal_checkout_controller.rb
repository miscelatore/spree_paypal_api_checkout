module Spree
  class PaypalCheckoutController < StoreController
    skip_before_action :verify_authenticity_token
    def express
      order = current_order || raise(ActiveRecord::RecordNotFound)
      items = order.line_items.map(&method(:line_item))

      additional_adjustments = order.all_adjustments.additional
      tax_adjustments = additional_adjustments.tax
      shipping_adjustments = additional_adjustments.shipping

      additional_adjustments.eligible.each do |adjustment|
        # Because PayPal doesn't accept $0 items at all. See #10
        # https://cms.paypal.com/uk/cgi-bin/?cmd=_render-content&content_ID=developer/e_howto_api_ECCustomizing
        # "It can be a positive or negative value but not zero."
        next if adjustment.amount.zero?
        next if tax_adjustments.include?(adjustment) || shipping_adjustments.include?(adjustment)

        items << {
          name: adjustment.label,
          quantity: 1,
          amount: {
            currency_code: order.currency,
            value: adjustment.amount
          }
        }
      end

      pp_response = provider.create_order(order, express_checkout_request_details(order, items))

      render json: pp_response
    end

    def confirm
      order = current_order || raise(ActiveRecord::RecordNotFound)
      response = provider.capture_payment(params[:number])
      order.payments.create!({
        source: Spree::PaypalApiCheckout.create({
          token: response['id'],
          payer_id: response['payer']['payer_id']
        }),
        amount: order.total,
        payment_method: payment_method
      })
      render json: response
    end

    def proceed
      order = current_order || raise(ActiveRecord::RecordNotFound)
      order.payments.last.source.update(transaction_id: params[:transaction_id])
      order.next
      path = checkout_state_path(order.state)
      if order.complete?
        flash.notice = Spree.t(:order_processed_successfully)
        flash[:order_completed] = true
        session[:order_id] = nil
        path = completion_route(order)
      end
      render json: { redirect_to: path }
    end

    def cancel
      flash[:notice] = Spree.t('flash.cancel', scope: 'paypal')
      order = current_order || raise(ActiveRecord::RecordNotFound)
      redirect_to checkout_state_path(order.state, paypal_cancel_token: params[:token])
    end

    private

    def line_item(item)
      {
          name: item.product.name,
          number: item.variant.sku,
          quantity: item.quantity,
          amount: {
            currency_code: item.order.currency,
            value: item.price
          },
          ItemCategory: "Physical"
      }
    end

    def express_checkout_request_details order, items
      {
        intent: 'CAPTURE',
        purchase_units: [
          {
            amount: {
              currency_code: current_order.currency,
              value: order.total
            },
            item: items
          },
        ]
      }
    end

    def payment_method
      Spree::PaymentMethod.find(params[:payment_method_id])
    end

    def provider
      payment_method
    end

    def completion_route(order)
      order_path(order)
    end
  end
end
