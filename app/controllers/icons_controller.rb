# The nodes' profile icons (V2.5), by their icon_hash: /icons/<hash>.png.
# A hash names one icon for good, so the browser may keep it.
class IconsController < ApplicationController
  def show
    icon = NodeIcon.find_by(icon_hash: params[:hash].to_s)
    return head :not_found unless icon
    expires_in 1.year, public: false
    send_data icon.png, type: "image/png", disposition: "inline"
  end
end
