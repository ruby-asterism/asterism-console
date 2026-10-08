Rails.application.routes.draw do
  root "console#show"
  resource :graph, only: :show
  resources :bridge_requests, only: %i[create show]
  resources :watches, only: %i[index create destroy]

  get "up" => "rails/health#show", as: :rails_health_check
end
