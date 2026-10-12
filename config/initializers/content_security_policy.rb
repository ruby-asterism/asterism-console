# The page's content security policy (W4), in every environment so the
# development server shows what production enforces:
#
# - scripts: this origin only, and the import map's inline script with a
#   per-request nonce. No eval, no inline handlers.
# - styles: this origin and nonce'd style elements; Turbo's progress bar
#   also by its hash (Turbo Drive keeps the first page's policy while it
#   takes the next page's nonce, so the nonce alone fails after a visit);
#   style attributes are allowed (the pages build swatches and badges with
#   them), which lets nothing run.
# - images: this origin, data: (camera pictures and marks) and blob:.
# - connections: this origin (the pages' fetches and the Action Cable
#   WebSocket, same origin).
# - no plugins, no framing, forms post here only.
# The hash of the style element turbo-rails 2.x adds for its progress bar.
TURBO_PROGRESS_BAR = "'sha256-pgvDUBa4IjFA2yuSJ2cqcyxmNYJMborsd0ORcRv9vw8='".freeze

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src :self
    policy.style_src :self, TURBO_PROGRESS_BAR
    policy.style_src_attr :unsafe_inline
    policy.img_src :self, :data, :blob
    policy.font_src :self, :data
    policy.connect_src :self
    policy.object_src :none
    policy.base_uri :self
    policy.form_action :self
    policy.frame_ancestors :none
  end

  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src style-src]
  config.content_security_policy_nonce_auto = true
end
