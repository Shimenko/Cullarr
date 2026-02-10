Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  resource :session, only: %i[new create destroy]

  root "dashboard#show"

  get "dashboard", to: "dashboard#show"
  get "ui",
      to: "ui/styleguide#show",
      as: :ui_styleguide,
      constraints: lambda { |_request|
        Rails.env.development? || Rails.env.test?
      }
  resource :settings, only: %i[show update], controller: :settings
  get "runs", to: "runs#index"
  post "runs/sync-now", to: "runs#sync_now", as: :runs_sync_now

  resources :integrations, only: %i[create update destroy] do
    post :check, on: :member
    resources :path_mappings, only: %i[create update destroy]
  end

  resources :path_exclusions, only: %i[create update destroy]

  resource :security, only: [], controller: :security do
    post :re_authenticate
    patch :update_password
  end

  namespace :api do
    namespace :v1 do
      defaults format: :json do
        get "health", to: "health#show"
        resource :settings, only: %i[show update]
        resources :integrations, only: %i[index create update destroy] do
          post :check, on: :member
          resources :path_mappings, only: %i[index create update destroy], controller: :path_mappings
        end
        resources :path_exclusions, only: %i[index create update destroy]
        resources :keep_markers, only: %i[index create destroy]
        resources :sync_runs, path: "sync-runs", only: %i[index show create]
        resources :candidates, only: :index
        resources :saved_views, path: "saved-views", only: %i[index create update]
        resource :operator_password, only: %i[update]
        post "security/re-auth", to: "security/re_auth#create"
      end
    end
  end
end
