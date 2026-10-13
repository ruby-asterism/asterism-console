Rails.application.routes.draw do
  resource :session, only: %i[ new create destroy ] do
    get :otp
    post :otp, action: :verify_otp, as: :verify_otp
  end
  resource :account, only: :show do
    patch :password, action: :update_password
    patch :handle, action: :update_handle
    post :otp, action: :start_otp, as: :start_otp
    post :otp_confirm, action: :confirm_otp
    delete :otp, action: :disable_otp, as: :disable_otp
  end

  root "console#show"
  resource :graph, only: :show
  resources :bridge_requests, only: %i[create show]
  resources :watches, only: %i[index create destroy]
  resources :rates, only: :create
  resource :plots, only: :show do
    post :lease
    post :release
  end
  resource :logs, only: :show do
    post :lease
    post :release
  end
  # Recordings (V4): record, list, upload, download, the timeline, the graph
  # rewind, and playback to the network.
  resources :recordings, only: %i[index create show destroy] do
    member do
      post :stop
      get :download
      get :ticks
      get :message
      get :fields
      get :series
      get :graph
      get :structure
    end
    post :upload, on: :collection
  end
  resources :playbacks, only: %i[create show] do
    post :stop, on: :member
  end
  # Names of machines of ROS 2 nodes (V2.3), from the graph's details.
  resources :machine_names, only: %i[index create update destroy]
  resources :calls, only: :index
  # The icons of the nodes' profiles (V2.5).
  get "icons/:hash", to: "icons#show", as: :icon, format: false

  # The call permissions that cover one object (the graph page asks; JSON).
  get "permissions", to: "call_permissions#covering", as: :covering_permissions

  # Passes for the browser build's wss:// (W4): a signed-in user makes one;
  # the proxy in front of the router asks check (no session: the proxy's
  # subrequest) whether a pass may open a connection.
  # "Open the browser build" (G1.5): a pass, a node ID for the user and the
  # app to start, handed to a page configured by ASTERISM_BROWSER_PAGE.
  resources :browser_passes, path: "passes", only: %i[index create] do
    patch :revoke, on: :member
    get :check, on: :collection
    post :open, on: :collection
  end

  # Joining by invitation (there is no sign-up page).
  resources :invitations, only: %i[show update], param: :token

  # Everything an admin manages lives under /admin, one prefix that the
  # proxy can limit by address (deploy/vps/nginx) on top of the admin role
  # (and CONSOLE_ADMIN_NETS here): the relay registry, certificates and
  # apply, the call permissions, the users and invitations, every pass.
  scope "admin" do
    resources :call_permissions, only: %i[index create destroy]
    # The relay: registry, roles, certificates (through the signer, or imported), apply.
    namespace :relay do
      resources :peers do
        resources :certificates, only: :create do
          patch :revoke, on: :member
        end
      end
      resources :roles
      resources :applies, only: %i[index new create show] do
        patch :cancel, on: :member
      end
      get "/", to: redirect("/admin/relay/peers")
    end
    namespace :admin, path: "" do
      resources :users, only: %i[index update destroy] do
        delete :otp, on: :member, action: :otp_off
      end
      resources :invitations, only: %i[index create] do
        patch :revoke, on: :member
      end
      resources :browser_passes, path: "passes", only: :index
    end
    get "/", to: redirect("/admin/relay/peers"), as: :admin_root
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
