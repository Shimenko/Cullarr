class ApplicationMailer < ActionMailer::Base
  default from: "from@example.com"
  layout :mailer_layout

  private

  def mailer_layout
    "mailer"
  end
end
