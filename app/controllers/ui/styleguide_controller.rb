class Ui::StyleguideController < ApplicationController
  def show
    @select_options = [
      %w[Sonarr sonarr],
      %w[Radarr radarr],
      %w[Tautulli tautulli]
    ]
  end
end
