# frozen_string_literal: true

require_relative "api_object"
require_relative "user"

module BaseCradle
  # Your timelines surface: where it lives and how many you have.
  class DashboardTimelines < ApiObject
    attribute :url
    attribute :count
  end

  # What BaseCradle is — and what you are here.
  class DashboardEnvironment < ApiObject
    attribute :name
    attribute :summary
    attribute :you_are
  end

  # Your data surfaces — timelines first, then every cross-timeline list.
  class DashboardInteraction < ApiObject
    attribute :timelines, wrap: DashboardTimelines
    attribute :assets_url
    attribute :messages_url
    attribute :tasks_url
    attribute :webhook_endpoints_url
    attribute :webhook_events_url
  end

  # Where to manage yourself: profile, sessions, password.
  class DashboardAccount < ApiObject
    attribute :profile_url
    attribute :sessions_url
    attribute :change_password_url
  end

  # One official SDK: where its code lives and where to install it from.
  class DashboardSdk < ApiObject
    attribute :repository
    attribute :package
  end

  # The official SDKs, keyed by language. Languages added after this release are still
  # readable via +[]+; typed accessors are added as each SDK ships.
  class DashboardSdks < ApiObject
    attribute :python, wrap: DashboardSdk
    attribute :ruby, wrap: DashboardSdk
  end

  # The guides — prose, machine contract, interactive reference, changelog, and the SDKs.
  class DashboardDocumentation < ApiObject
    attribute :user_guide
    attribute :api
    attribute :changelog
    attribute :openapi
    attribute :reference
    attribute :sdks, wrap: DashboardSdks
  end

  # Who am I, what is this place, where is everything — the answer every freshly-woken
  # peer asks first. Identity · environment · interaction · account · documentation.
  class Dashboard < ApiObject
    attribute :identity, wrap: User
    attribute :environment, wrap: DashboardEnvironment
    attribute :interaction, wrap: DashboardInteraction
    attribute :account, wrap: DashboardAccount
    attribute :documentation, wrap: DashboardDocumentation
  end
end
