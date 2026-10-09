Rails.application.routes.draw do
  resource :session, only: %i[ new create destroy ] do
    get :otp
    post :otp, action: :verify_otp, as: :verify_otp
  end
  resource :account, only: :show do
    patch :password, action: :update_password
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
  resources :call_permissions, only: %i[index create destroy]
  resources :calls, only: :index

  # The relay: registry, certificates (through the signer), apply.
  namespace :relay do
    resources :peers do
      resources :certificates, only: :create do
        patch :revoke, on: :member
      end
    end
    resources :applies, only: %i[index new create show]
    get "/", to: redirect("/relay/peers")
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
