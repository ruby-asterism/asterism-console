require "rqrcode"

module AccountsHelper
  # The TOTP URI as a QR code, inline SVG made on the server (no script,
  # no image request), for an authenticator app to scan from the screen.
  # Black on white with a quiet zone, whatever the page's theme.
  def otp_qr_svg(uri)
    svg = RQRCode::QRCode.new(uri, level: :m).as_svg(
      use_path: true, viewbox: true, module_size: 4, offset: 16,
      color: "000", fill: "fff",
      svg_attributes: { class: "qr", role: "img", "aria-label": "QR code of the URI below" }
    )
    svg.sub(/\A<\?xml[^>]*\?>/, "").html_safe # made by rqrcode from the URI, no user markup
  end
end
