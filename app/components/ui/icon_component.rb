# frozen_string_literal: true

require "erb"

class Ui::IconComponent < Ui::BaseComponent
  NAME_ALIASES = {
    "alert-triangle" => "triangle-alert"
  }.freeze

  SIZES = {
    sm: 16,
    md: 20,
    lg: 24
  }.freeze

  def initialize(
    name:,
    size: :md,
    stroke_width: 1.5,
    decorative: true,
    title: nil,
    class_name: nil,
    data: nil,
    **html_options
  )
    super(class_name:, data:, **html_options)
    @name = normalize_name(name)
    @size = normalized_option(name: :size, value: size, allowed: SIZES.keys)
    @decorative = normalized_boolean(name: :decorative, value: decorative)
    @title = title
    @stroke_width = normalize_stroke_width(stroke_width)

    return if @decorative || @title.present?

    raise ArgumentError, "#{self.class.name} requires title when decorative is false."
  end

  private

  attr_reader :name, :size, :decorative, :title, :stroke_width

  def svg_markup
    icon_markup = File.read(icon_path)
    opening_tag_match = icon_markup.match(/<svg\b[^>]*>/)
    raise ArgumentError, "#{self.class.name} icon '#{name}' is not a valid SVG." unless opening_tag_match

    opening_tag = opening_tag_match[0]
    with_attributes = icon_markup.sub(opening_tag, "<svg #{svg_attributes}>")
    return with_attributes.html_safe unless title.present?

    with_attributes.sub("<svg #{svg_attributes}>", "<svg #{svg_attributes}><title>#{ERB::Util.html_escape(title)}</title>").html_safe
  end

  def icon_path
    path = Rails.root.join("app/assets/icons/lucide/#{name}.svg")
    return path if File.file?(path)

    raise ArgumentError, "#{self.class.name} icon '#{name}' is not available."
  end

  def pixel_size
    SIZES.fetch(size)
  end

  def svg_attributes
    options = html_attributes(
      default_classes: %W[ui-icon ui-icon-#{size}],
      role: decorative ? "presentation" : "img",
      "aria-hidden": decorative ? "true" : nil,
      "aria-label": title.presence,
      focusable: "false"
    )

    options[:width] = pixel_size
    options[:height] = pixel_size
    options[:fill] = "none"
    options[:stroke] = "currentColor"
    options[:"stroke-width"] = stroke_width

    flatten_html_attributes(options)
  end

  def flatten_html_attributes(options)
    options.flat_map do |key, value|
      case key
      when :data
        value.map do |data_key, data_value|
          [ "data-#{data_key.to_s.tr('_', '-')}", data_value ]
        end
      when :aria
        value.map do |aria_key, aria_value|
          [ "aria-#{aria_key.to_s.tr('_', '-')}", aria_value ]
        end
      else
        [ [ key.to_s.tr("_", "-"), value ] ]
      end
    end.each_with_object([]) do |(attr, value), pairs|
      next if value.nil?

      pairs << %(#{attr}="#{ERB::Util.html_escape(value)}")
    end.join(" ")
  end

  def normalize_name(value)
    normalized = value.to_s
    normalized = NAME_ALIASES.fetch(normalized, normalized)

    return normalized if normalized.match?(/\A[a-z0-9-]+\z/)

    raise ArgumentError, "#{self.class.name} received invalid icon name: #{value.inspect}."
  end

  def normalize_stroke_width(value)
    Float(value)
  rescue ArgumentError, TypeError
    raise ArgumentError, "#{self.class.name} expected stroke_width to be numeric."
  end
end
