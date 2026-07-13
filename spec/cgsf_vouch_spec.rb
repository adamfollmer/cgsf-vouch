# frozen_string_literal: true

require "rails_helper"

describe "cgsf-vouch", type: :request do
  fab!(:adam) do
    SiteSetting.vouch_enabled = true
    Fabricate(:user, name: nil)
  end
  fab!(:jane) { Fabricate(:user, name: nil) }
  fab!(:sarah) { Fabricate(:user, name: nil) }
  fab!(:miguel) { Fabricate(:user, name: nil) }

  def offer!(from, to)
    ::CgsfVouch::Vouch.create!(requester_id: from.id, receiver_id: to.id)
  end

  def edge!(a, b)
    ::CgsfVouch::Vouch.create!(
      requester_id: a.id,
      receiver_id: b.id,
      confirmed_at: Time.zone.now,
    )
  end

  describe "offering" do
    before { sign_in(adam) }

    it "creates a pending offer and notifies the receiver" do
      post "/cgsf-vouch/offers.json", params: { username: jane.username }
      expect(response.status).to eq(200)

      vouch = ::CgsfVouch::Vouch.last
      expect(vouch.requester_id).to eq(adam.id)
      expect(vouch.receiver_id).to eq(jane.id)
      expect(vouch.confirmed_at).to be_nil

      notification = jane.notifications.last
      expect(notification.notification_type).to eq(Notification.types[:vouch_offer])
      expect(JSON.parse(notification.data)["vouch_id"]).to eq(vouch.id)
    end

    it "refuses self-vouching" do
      post "/cgsf-vouch/offers.json", params: { username: adam.username }
      expect(response.status).to eq(403)
    end

    it "refuses a duplicate offer in either direction" do
      offer!(adam, jane)
      post "/cgsf-vouch/offers.json", params: { username: jane.username }
      expect(response.status).to eq(422)

      ::CgsfVouch::Vouch.destroy_all
      offer!(jane, adam)
      post "/cgsf-vouch/offers.json", params: { username: jane.username }
      expect(response.status).to eq(422)
    end

    it "refuses when an edge already exists" do
      edge!(adam, jane)
      post "/cgsf-vouch/offers.json", params: { username: jane.username }
      expect(response.status).to eq(422)
    end
  end

  describe "accepting" do
    it "confirms the edge, clears the offer notification, notifies the requester" do
      sign_in(adam)
      post "/cgsf-vouch/offers.json", params: { username: jane.username }
      vouch = ::CgsfVouch::Vouch.last

      sign_in(jane)
      put "/cgsf-vouch/offers/#{vouch.id}/accept.json"
      expect(response.status).to eq(200)
      expect(vouch.reload.confirmed_at).to be_present

      expect(
        jane.notifications.where(notification_type: Notification.types[:vouch_offer]).count,
      ).to eq(0)
      accepted = adam.notifications.last
      expect(accepted.notification_type).to eq(Notification.types[:vouch_accepted])
    end

    it "cannot be accepted by anyone but the receiver" do
      vouch = offer!(adam, jane)
      sign_in(sarah)
      put "/cgsf-vouch/offers/#{vouch.id}/accept.json"
      expect(response.status).to eq(404)
      expect(vouch.reload.confirmed_at).to be_nil
    end
  end

  describe "dismissing (the invisible no)" do
    it "closes quietly: notification gone, requester gets nothing, cooldown holds" do
      sign_in(adam)
      post "/cgsf-vouch/offers.json", params: { username: jane.username }
      vouch = ::CgsfVouch::Vouch.last
      requester_notifications_before = adam.notifications.count

      sign_in(jane)
      put "/cgsf-vouch/offers/#{vouch.id}/dismiss.json"
      expect(response.status).to eq(200)

      vouch.reload
      expect(vouch.confirmed_at).to be_nil
      expect(vouch.cooldown_until).to be_present
      expect(jane.notifications.count).to eq(0)
      expect(adam.notifications.count).to eq(requester_notifications_before)

      sign_in(adam)
      post "/cgsf-vouch/offers.json", params: { username: jane.username }
      expect(response.status).to eq(422)
    end

    it "stores a dismissal byte-identically to an expiry" do
      dismissed = offer!(adam, jane)
      expired = offer!(adam, sarah)

      sign_in(jane)
      put "/cgsf-vouch/offers/#{dismissed.id}/dismiss.json"

      freeze_time (SiteSetting.vouch_offer_expiry_days + 1).days.from_now do
        ::CgsfVouch::Vouch.expire_stale!
      end

      expect(dismissed.reload.cooldown_until).to eq_time(
        dismissed.created_at + ::CgsfVouch::Vouch.close_window_days.days,
      )
      expect(expired.reload.cooldown_until).to eq_time(
        expired.created_at + ::CgsfVouch::Vouch.close_window_days.days,
      )
      # Both rows carry cooldown_until = created_at + the same constant, and
      # update_columns skipped updated_at — nothing distinguishes them.
      expect(dismissed.updated_at).to eq_time(dismissed.created_at)
    end

    it "lets the dismisser offer in the other direction during the cooldown" do
      vouch = offer!(adam, jane)
      sign_in(jane)
      put "/cgsf-vouch/offers/#{vouch.id}/dismiss.json"

      post "/cgsf-vouch/offers.json", params: { username: adam.username }
      expect(response.status).to eq(200)
    end

    it "allows re-offering after the cooldown passes" do
      vouch = offer!(adam, jane)
      sign_in(jane)
      put "/cgsf-vouch/offers/#{vouch.id}/dismiss.json"

      freeze_time (::CgsfVouch::Vouch.close_window_days + 1).days.from_now do
        sign_in(adam)
        post "/cgsf-vouch/offers.json", params: { username: jane.username }
        expect(response.status).to eq(200)
      end
    end
  end

  describe "expiry" do
    it "quietly closes stale offers and removes the receiver's notification" do
      sign_in(adam)
      post "/cgsf-vouch/offers.json", params: { username: jane.username }
      vouch = ::CgsfVouch::Vouch.last

      freeze_time (SiteSetting.vouch_offer_expiry_days + 1).days.from_now do
        ::CgsfVouch::Vouch.expire_stale!
      end

      expect(vouch.reload.cooldown_until).to be_present
      expect(
        jane.notifications.where(notification_type: Notification.types[:vouch_offer]).count,
      ).to eq(0)
    end

    it "purges rows whose cooldown has fully passed" do
      vouch = offer!(adam, jane)
      vouch.close_quietly!

      freeze_time (::CgsfVouch::Vouch.close_window_days + 1).days.from_now do
        Jobs::CgsfVouchTidy.new.execute({})
      end
      expect(::CgsfVouch::Vouch.exists?(vouch.id)).to eq(false)
    end
  end

  describe "withdrawing" do
    it "deletes the edge with no notification to either side" do
      edge!(adam, jane)
      jane_before = jane.notifications.count
      sign_in(adam)

      delete "/cgsf-vouch/edges/#{jane.username}.json"
      expect(response.status).to eq(200)
      expect(::CgsfVouch::Vouch.count).to eq(0)
      expect(jane.notifications.count).to eq(jane_before)
    end
  end

  describe "relation" do
    before { sign_in(adam) }

    it "reports a mutual edge" do
      edge!(adam, jane)
      get "/cgsf-vouch/relation/#{jane.username}.json"
      json = response.parsed_body
      expect(json["mutual"]).to eq(true)
      expect(json["can_vouch"]).to eq(false)
    end

    it "reports one step away with the intermediary's name" do
      edge!(adam, sarah)
      edge!(sarah, jane)
      get "/cgsf-vouch/relation/#{jane.username}.json"
      json = response.parsed_body
      expect(json["steps"]).to eq(2)
      expect(json["via_name"]).to eq(sarah.username)
      expect(json["can_vouch"]).to eq(true)
    end

    it "reports two steps away without naming anyone" do
      edge!(adam, sarah)
      edge!(sarah, miguel)
      edge!(miguel, jane)
      get "/cgsf-vouch/relation/#{jane.username}.json"
      json = response.parsed_body
      expect(json["steps"]).to eq(3)
      expect(json["via_name"]).to be_nil
    end

    it "reports no path for strangers" do
      get "/cgsf-vouch/relation/#{jane.username}.json"
      json = response.parsed_body
      expect(json["steps"]).to be_nil
      expect(json["can_vouch"]).to eq(true)
    end

    it "hides the button after an offer without revealing why" do
      offer!(adam, jane)
      get "/cgsf-vouch/relation/#{jane.username}.json"
      expect(response.parsed_body["can_vouch"]).to eq(false)
    end
  end

  describe "your web" do
    it "returns rings and pending offers for the current user only" do
      edge!(adam, sarah)
      edge!(sarah, jane)
      edge!(jane, miguel)
      offer!(miguel, adam)

      sign_in(adam)
      get "/cgsf-vouch/web.json"
      json = response.parsed_body
      expect(json["vouched"].map { |u| u["username"] }).to eq([sarah.username])
      expect(json["one_step_count"]).to eq(1)
      expect(json["two_step_count"]).to eq(1)
      expect(json["pending_offers"].map { |o| o["username"] }).to eq([miguel.username])
    end

    it "requires login" do
      get "/cgsf-vouch/web.json"
      expect(response.status).to eq(403)
    end
  end
end
