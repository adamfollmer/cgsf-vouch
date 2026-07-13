import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { next } from "@ember/runloop";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

export default class VouchCardInfo extends Component {
  @service currentUser;
  @service dialog;

  @tracked relation = null;
  @tracked justOffered = false;
  @tracked busy = false;
  loadedFor = null;

  get user() {
    return this.args.outletArgs.user;
  }

  get show() {
    return (
      this.currentUser &&
      this.user &&
      this.user.username !== this.currentUser.username
    );
  }

  // The card component persists while @user changes between card openings,
  // so reload whenever the username we rendered for goes stale. Read the
  // tracked `relation` unconditionally — the early-return path must still
  // depend on it or the getter never recomputes once the ajax result lands.
  get data() {
    const relation = this.relation;
    if (!this.show) {
      return null;
    }
    if (this.loadedFor !== this.user.username) {
      this.loadedFor = this.user.username;
      next(() => this.load(this.user.username));
      return null;
    }
    return relation;
  }

  async load(username) {
    this.justOffered = false;
    this.relation = null;
    try {
      const result = await ajax(
        `/cgsf-vouch/relation/${encodeURIComponent(username)}.json`
      );
      if (this.loadedFor === username) {
        this.relation = result;
      }
    } catch {
      // fail quiet on the card
    }
  }

  get stepsText() {
    const d = this.data;
    if (!d || d.mutual || d.self) {
      return null;
    }
    if (d.steps === 2) {
      return i18n("cgsf_vouch.card.one_step", { via: d.via_name });
    }
    if (d.steps === 3) {
      return i18n("cgsf_vouch.card.two_steps");
    }
    return i18n("cgsf_vouch.card.no_path");
  }

  offer = async () => {
    this.busy = true;
    try {
      await ajax("/cgsf-vouch/offers", {
        type: "POST",
        data: { username: this.user.username },
      });
      this.justOffered = true;
      this.relation = { ...this.relation, can_vouch: false };
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.busy = false;
    }
  };

  acceptOffer = async () => {
    this.busy = true;
    try {
      await ajax(`/cgsf-vouch/offers/${this.data.pending_offer_id}/accept`, {
        type: "PUT",
      });
      await this.load(this.user.username);
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.busy = false;
    }
  };

  dismissOffer = async () => {
    this.busy = true;
    try {
      await ajax(`/cgsf-vouch/offers/${this.data.pending_offer_id}/dismiss`, {
        type: "PUT",
      });
      await this.load(this.user.username);
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.busy = false;
    }
  };

  withdraw = () => {
    const name = this.user.name || this.user.username;
    this.dialog.yesNoConfirm({
      message: i18n("cgsf_vouch.card.withdraw_confirm", { name }),
      didConfirm: async () => {
        try {
          await ajax(
            `/cgsf-vouch/edges/${encodeURIComponent(this.user.username)}`,
            { type: "DELETE" }
          );
          await this.load(this.user.username);
        } catch (e) {
          popupAjaxError(e);
        }
      },
    });
  };

  <template>
    {{#if this.show}}
      {{#if this.data}}
        <div class="cgsf-vouch-card">
          {{#if this.data.mutual}}
            <span class="cgsf-vouch-card__mutual">
              {{i18n "cgsf_vouch.card.mutual"}}
            </span>
            <DButton
              @action={{this.withdraw}}
              @translatedLabel={{i18n "cgsf_vouch.card.withdraw"}}
              class="btn-flat cgsf-vouch-card__withdraw"
            />
          {{else if this.data.pending_offer_id}}
            <p class="cgsf-vouch-card__question">
              {{i18n
                "cgsf_vouch.card.offer_question"
                name=this.data.pending_offer_name
              }}
            </p>
            <DButton
              @action={{this.acceptOffer}}
              @translatedLabel={{i18n "cgsf_vouch.card.vouch_back"}}
              @disabled={{this.busy}}
              @icon="handshake"
              class="btn-primary"
            />
            <DButton
              @action={{this.dismissOffer}}
              @translatedLabel={{i18n "cgsf_vouch.card.not_now"}}
              @disabled={{this.busy}}
              class="btn-flat"
            />
          {{else}}
            {{#if this.stepsText}}
              <span class="cgsf-vouch-card__steps">{{this.stepsText}}</span>
            {{/if}}
            {{#if this.justOffered}}
              <span class="cgsf-vouch-card__sent">
                {{i18n "cgsf_vouch.card.offer_sent"}}
              </span>
            {{else if this.data.can_vouch}}
              <DButton
                @action={{this.offer}}
                @translatedLabel={{i18n "cgsf_vouch.card.vouch_button"}}
                @disabled={{this.busy}}
                @icon="handshake"
                class="cgsf-vouch-card__offer"
              />
            {{/if}}
          {{/if}}
        </div>
      {{/if}}
    {{/if}}
  </template>
}
