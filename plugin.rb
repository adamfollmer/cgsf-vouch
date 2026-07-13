# frozen_string_literal: true

# name: cgsf-vouch
# about: Neighbor vouching — mutual real-life trust, shown as paths between people, never as scores
# version: 0.1.0
# authors: Adam F.
# url: https://github.com/adamfollmer/cgsf-vouch
# required_version: 2.7.0

enabled_site_setting :vouch_enabled

register_asset "stylesheets/cgsf-vouch.scss"
register_svg_icon "handshake"

module ::CgsfVouch
  PLUGIN_NAME = "cgsf-vouch"
end

require_relative "lib/cgsf_vouch/engine"

after_initialize do
  Notification.types[:vouch_offer] = 950
  Notification.types[:vouch_accepted] = 951

  class ::CgsfVouch::Vouch < ::ActiveRecord::Base
    self.table_name = "cgsf_vouches"

    scope :confirmed, -> { where.not(confirmed_at: nil) }
    # Pending = awaiting an answer. Closed rows (cooldown_until set) exist only
    # to hold the re-offer cooldown; expired and dismissed offers are stored
    # byte-identically so the database never records that a "no" happened.
    scope :pending, -> { where(confirmed_at: nil, cooldown_until: nil) }

    def self.close_window_days
      SiteSetting.vouch_offer_expiry_days + SiteSetting.vouch_reoffer_cooldown_days
    end

    def close_quietly!
      update_columns(cooldown_until: created_at + self.class.close_window_days.days)
      Notification.where(
        user_id: receiver_id,
        notification_type: Notification.types[:vouch_offer],
      ).where("data LIKE ?", "%\"vouch_id\":#{id}%").destroy_all
    end

    def self.between(a_id, b_id)
      where(
        "(requester_id = :a AND receiver_id = :b) OR (requester_id = :b AND receiver_id = :a)",
        a: a_id,
        b: b_id,
      )
    end

    def self.edge?(a_id, b_id)
      between(a_id, b_id).confirmed.exists?
    end

    def self.neighbor_ids(user_id)
      confirmed
        .where("requester_id = :id OR receiver_id = :id", id: user_id)
        .pluck(:requester_id, :receiver_id)
        .flatten
        .uniq - [user_id]
    end

    def self.neighbor_ids_of(ids)
      return [] if ids.empty?
      confirmed
        .where("requester_id IN (:ids) OR receiver_id IN (:ids)", ids: ids)
        .pluck(:requester_id, :receiver_id)
        .flatten
        .uniq
    end

    # Distance in the member-facing sense: 1 = you vouch for each other,
    # 2 = one person between you (returns who), 3 = two people between you.
    def self.relation_between(viewer_id, target_id)
      n1 = neighbor_ids(viewer_id)
      return [1, nil] if n1.include?(target_id)
      target_n1 = neighbor_ids(target_id)
      via = (n1 & target_n1).first
      return [2, via] if via
      ring2 = neighbor_ids_of(n1) - n1 - [viewer_id]
      return [3, nil] if (ring2 & target_n1).any?
      [nil, nil]
    end

    def self.web_rings(user_id)
      n1 = neighbor_ids(user_id)
      ring2 = neighbor_ids_of(n1) - n1 - [user_id]
      ring3 = neighbor_ids_of(ring2) - ring2 - n1 - [user_id]
      [n1, ring2, ring3]
    end

    def self.expire_stale!
      pending
        .where("created_at < ?", SiteSetting.vouch_offer_expiry_days.days.ago)
        .find_each(&:close_quietly!)
    end
  end

  class ::CgsfVouch::VouchesController < ::ApplicationController
    requires_plugin ::CgsfVouch::PLUGIN_NAME
    before_action :ensure_logged_in
    skip_before_action :check_xhr, only: [:page]

    def page
      render "default/empty"
    end

    def create
      target = User.real.find_by(username_lower: params.require(:username).downcase)
      raise Discourse::NotFound if target.nil? || target.staged?
      raise Discourse::InvalidAccess if target.id == current_user.id

      ::CgsfVouch::Vouch.expire_stale!
      pair = ::CgsfVouch::Vouch.between(current_user.id, target.id)
      pair.where("cooldown_until IS NOT NULL AND cooldown_until < ?", Time.zone.now).destroy_all

      if pair.confirmed.exists? || pair.pending.exists? ||
           pair.where(requester_id: current_user.id).where.not(cooldown_until: nil).exists?
        return render_json_error(I18n.t("cgsf_vouch.errors.cannot_vouch_now"), status: 422)
      end

      vouch = ::CgsfVouch::Vouch.create!(requester_id: current_user.id, receiver_id: target.id)
      Notification.create!(
        user_id: target.id,
        notification_type: Notification.types[:vouch_offer],
        data: {
          vouch_id: vouch.id,
          display_name: current_user.name.presence || current_user.username,
          username: current_user.username,
        }.to_json,
      )
      render json: success_json
    end

    def accept
      vouch = ::CgsfVouch::Vouch.pending.find_by(id: params[:id], receiver_id: current_user.id)
      raise Discourse::NotFound if vouch.nil?

      vouch.update!(confirmed_at: Time.zone.now)
      Notification.where(
        user_id: current_user.id,
        notification_type: Notification.types[:vouch_offer],
      ).where("data LIKE ?", "%\"vouch_id\":#{vouch.id}%").destroy_all
      Notification.create!(
        user_id: vouch.requester_id,
        notification_type: Notification.types[:vouch_accepted],
        data: {
          vouch_id: vouch.id,
          display_name: current_user.name.presence || current_user.username,
          username: current_user.username,
        }.to_json,
      )
      render json: success_json
    end

    def dismiss
      vouch = ::CgsfVouch::Vouch.pending.find_by(id: params[:id], receiver_id: current_user.id)
      raise Discourse::NotFound if vouch.nil?

      vouch.close_quietly!
      render json: success_json
    end

    def withdraw
      other = User.find_by(username_lower: params.require(:username).downcase)
      raise Discourse::NotFound if other.nil?
      edge = ::CgsfVouch::Vouch.between(current_user.id, other.id).confirmed.first
      raise Discourse::NotFound if edge.nil?

      edge.destroy!
      render json: success_json
    end

    def relation
      target = User.real.find_by(username_lower: params.require(:username).downcase)
      raise Discourse::NotFound if target.nil?

      if target.id == current_user.id
        return render json: { self: true }
      end

      ::CgsfVouch::Vouch.expire_stale!
      pair = ::CgsfVouch::Vouch.between(current_user.id, target.id)
      mutual = pair.confirmed.exists?
      pending_from_them = pair.pending.find_by(requester_id: target.id)
      blocked =
        pair.pending.where(requester_id: current_user.id).exists? ||
          pair
            .where(requester_id: current_user.id)
            .where("cooldown_until > ?", Time.zone.now)
            .exists?

      steps, via_id = ::CgsfVouch::Vouch.relation_between(current_user.id, target.id)
      via = via_id && User.find_by(id: via_id)

      render json: {
               mutual: mutual,
               steps: steps,
               via_name: via && (via.name.presence || via.username),
               can_vouch: !mutual && pending_from_them.nil? && !blocked,
               pending_offer_id: pending_from_them&.id,
               pending_offer_name:
                 pending_from_them &&
                   (target.name.presence || target.username),
             }
    end

    def web
      ::CgsfVouch::Vouch.expire_stale!
      ring1_ids, ring2, ring3 = ::CgsfVouch::Vouch.web_rings(current_user.id)
      vouched =
        User
          .where(id: ring1_ids)
          .order(:username)
          .map { |u| { username: u.username, name: u.name.presence || u.username } }
      offers =
        ::CgsfVouch::Vouch
          .pending
          .where(receiver_id: current_user.id)
          .order(:created_at)
          .includes(:requester)
          .map do |v|
            {
              id: v.id,
              username: v.requester.username,
              name: v.requester.name.presence || v.requester.username,
            }
          end

      render json: {
               vouched: vouched,
               one_step_count: ring2.size,
               two_step_count: ring3.size,
               pending_offers: offers,
             }
    end
  end

  class ::CgsfVouch::Vouch
    belongs_to :requester, class_name: "User"
    belongs_to :receiver, class_name: "User"
  end

  class ::Jobs::CgsfVouchTidy < ::Jobs::Scheduled
    every 1.day

    def execute(args)
      ::CgsfVouch::Vouch.expire_stale!
      # A row whose cooldown has fully passed no longer holds any rule — purge
      # it so no history of unanswered offers accumulates.
      ::CgsfVouch::Vouch
        .where("cooldown_until IS NOT NULL AND cooldown_until < ?", Time.zone.now)
        .delete_all
    end
  end

  Discourse::Application.routes.append do
    get "/your-web" => "cgsf_vouch/vouches#page"
    get "/cgsf-vouch/web" => "cgsf_vouch/vouches#web"
    get "/cgsf-vouch/relation/:username" => "cgsf_vouch/vouches#relation",
        :constraints => {
          username: RouteFormat.username,
        }
    post "/cgsf-vouch/offers" => "cgsf_vouch/vouches#create"
    put "/cgsf-vouch/offers/:id/accept" => "cgsf_vouch/vouches#accept"
    put "/cgsf-vouch/offers/:id/dismiss" => "cgsf_vouch/vouches#dismiss"
    delete "/cgsf-vouch/edges/:username" => "cgsf_vouch/vouches#withdraw",
           :constraints => {
             username: RouteFormat.username,
           }
  end
end
