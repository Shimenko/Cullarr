# UI Component Conventions

`Ui::*` components follow a small initializer and validation contract:

1. Inherit from `Ui::BaseComponent`.
2. Use keyword arguments only.
3. Accept `class_name:`, `data:`, and `**html_options` in each initializer, then call `super`.
4. Validate enum-like arguments with `normalized_option(name:, value:, allowed:)`.
5. Validate booleans with `normalized_boolean(name:, value:)`.
6. Build output attributes with `html_attributes(default_classes:, data:, **html_options)`.

This keeps component APIs consistent and testable as the primitive library grows.

Current primitives:
- `Ui::ButtonComponent`
- `Ui::IconButtonComponent`
- `Ui::IconComponent`
- `Ui::ChipComponent`
- `Ui::BadgeComponent`
- `Ui::PanelComponent`
- `Ui::InlineAlertComponent`
- `Ui::InputComponent`
- `Ui::SelectComponent`
- `Ui::CheckboxComponent`
- `Ui::SwitchComponent`
- `Ui::ProgressComponent`
