Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  resource :session, only: %i[new create destroy]

  root "dashboard#show"

  get "dashboard", to: "dashboard#show"
  get "settings", to: "settings#index"
  get "runs", to: "runs#index"

  get "api/v1/health", to: "api/v1/health#show", defaults: { format: :json }, as: :api_v1_health
end
