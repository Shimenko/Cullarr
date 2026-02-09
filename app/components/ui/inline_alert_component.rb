# frozen_string_literal: true

class Ui::InlineAlertComponent < Ui::BaseComponent
  KINDS = %i[info success warning danger].freeze

  FLASH_KIND_MAP = {
    notice: :success,
    alert: :danger
  }.freeze

  ICON_MAP = {
    info: "info",
    success: "circle-check",
    warning: "triangle-alert",
    danger: "circle-x"
  }.freeze

  def self.kind_for_flash_key(flash_key)
    FLASH_KIND_MAP.fetch(flash_key.to_sym, :info)
  end

  def initialize(message:, kind: :info, title: nil, icon: nil, class_name: nil, data: nil, **html_options)
    super(class_name:, data:, **html_options)
    @message = message
    @kind = normalized_option(name: :kind, value: kind, allowed: KINDS)
    @title = title
    @icon = icon
  end

  private

  attr_reader :message, :kind, :title, :icon

  def alert_attributes
    html_attributes(default_classes: %W[ui-inline-alert ui-inline-alert-#{kind}], role: "status")
  end

  def icon_name
    icon.presence || ICON_MAP.fetch(kind)
  end
end
