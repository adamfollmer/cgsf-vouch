import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

const RING_RADII = [70, 130, 190];
const CENTER = 210;

function initialsFor(name) {
  return name
    .split(/\s+/)
    .map((part) => part[0])
    .filter(Boolean)
    .slice(0, 2)
    .join("")
    .toUpperCase();
}

function ringDots(count, radius, cap) {
  const shown = Math.min(count, cap);
  const dots = [];
  for (let i = 0; i < shown; i++) {
    const angle = (2 * Math.PI * i) / shown - Math.PI / 2;
    dots.push({
      x: Math.round(CENTER + radius * Math.cos(angle)),
      y: Math.round(CENTER + radius * Math.sin(angle)),
    });
  }
  return dots;
}

export default class YourWebPage extends Component {
  @service dialog;

  @tracked vouched = this.args.data.vouched;
  @tracked pendingOffers = this.args.data.pending_offers;
  @tracked oneStepCount = this.args.data.one_step_count;
  @tracked twoStepCount = this.args.data.two_step_count;

  get ringOne() {
    const users = this.vouched.slice(0, 12);
    return ringDots(users.length, RING_RADII[0], 12).map((dot, i) => ({
      ...dot,
      initials: initialsFor(users[i].name),
      name: users[i].name,
    }));
  }

  get ringTwo() {
    return ringDots(this.oneStepCount, RING_RADII[1], 24);
  }

  get ringThree() {
    return ringDots(this.twoStepCount, RING_RADII[2], 36);
  }

  get radii() {
    return RING_RADII;
  }

  respond = async (offer, action) => {
    try {
      await ajax(`/cgsf-vouch/offers/${offer.id}/${action}`, { type: "PUT" });
      this.pendingOffers = this.pendingOffers.filter((o) => o.id !== offer.id);
      if (action === "accept") {
        this.vouched = [...this.vouched, offer].sort((a, b) =>
          a.username.localeCompare(b.username)
        );
      }
    } catch (e) {
      popupAjaxError(e);
    }
  };

  withdraw = (neighbor) => {
    this.dialog.yesNoConfirm({
      message: i18n("cgsf_vouch.card.withdraw_confirm", {
        name: neighbor.name,
      }),
      didConfirm: async () => {
        try {
          await ajax(
            `/cgsf-vouch/edges/${encodeURIComponent(neighbor.username)}`,
            { type: "DELETE" }
          );
          this.vouched = this.vouched.filter(
            (n) => n.username !== neighbor.username
          );
        } catch (e) {
          popupAjaxError(e);
        }
      },
    });
  };

  acceptOffer = (offer) => this.respond(offer, "accept");
  dismissOffer = (offer) => this.respond(offer, "dismiss");

  <template>
    <div class="cgsf-your-web">
      <h1>{{i18n "cgsf_vouch.web.title"}}</h1>
      <p class="cgsf-your-web__privacy">{{i18n "cgsf_vouch.web.privacy_note"}}</p>

      {{#if this.pendingOffers.length}}
        <section class="cgsf-your-web__pending">
          <h2>{{i18n "cgsf_vouch.web.pending_title"}}</h2>
          {{#each this.pendingOffers as |offer|}}
            <div class="cgsf-your-web__offer">
              <span class="cgsf-your-web__offer-text">
                {{i18n "cgsf_vouch.card.offer_question" name=offer.name}}
              </span>
              <DButton
                @action={{fn this.acceptOffer offer}}
                @translatedLabel={{i18n "cgsf_vouch.card.vouch_back"}}
                @icon="handshake"
                class="btn-primary"
              />
              <DButton
                @action={{fn this.dismissOffer offer}}
                @translatedLabel={{i18n "cgsf_vouch.card.not_now"}}
                class="btn-flat"
              />
            </div>
          {{/each}}
        </section>
      {{/if}}

      <div class="cgsf-your-web__body">
        <div class="cgsf-your-web__stats">
          <div class="cgsf-your-web__stat">
            <span class="cgsf-your-web__stat-number">{{this.vouched.length}}</span>
            <span class="cgsf-your-web__stat-label">{{i18n "cgsf_vouch.web.vouched_count"}}</span>
          </div>
          <div class="cgsf-your-web__stat">
            <span class="cgsf-your-web__stat-number">{{this.oneStepCount}}</span>
            <span class="cgsf-your-web__stat-label">{{i18n "cgsf_vouch.web.one_step_count"}}</span>
          </div>
          <div class="cgsf-your-web__stat">
            <span class="cgsf-your-web__stat-number">{{this.twoStepCount}}</span>
            <span class="cgsf-your-web__stat-label">{{i18n "cgsf_vouch.web.two_step_count"}}</span>
          </div>
        </div>

        <svg
          class="cgsf-your-web__rings"
          viewBox="0 0 420 420"
          role="img"
          aria-label={{i18n "cgsf_vouch.web.title"}}
        >
          {{#each this.radii as |r|}}
            <circle
              cx="210"
              cy="210"
              r={{r}}
              class="cgsf-your-web__ring-line"
            />
          {{/each}}
          {{#each this.ringThree as |dot|}}
            <circle cx={{dot.x}} cy={{dot.y}} r="3" class="cgsf-your-web__dot-far" />
          {{/each}}
          {{#each this.ringTwo as |dot|}}
            <circle cx={{dot.x}} cy={{dot.y}} r="5" class="cgsf-your-web__dot-mid" />
          {{/each}}
          {{#each this.ringOne as |dot|}}
            <line
              x1="210"
              y1="210"
              x2={{dot.x}}
              y2={{dot.y}}
              class="cgsf-your-web__spoke"
            />
          {{/each}}
          {{#each this.ringOne as |dot|}}
            <g>
              <title>{{dot.name}}</title>
              <circle cx={{dot.x}} cy={{dot.y}} r="15" class="cgsf-your-web__dot-near" />
              <text x={{dot.x}} y={{dot.y}} class="cgsf-your-web__initials">
                {{dot.initials}}
              </text>
            </g>
          {{/each}}
          <circle cx="210" cy="210" r="19" class="cgsf-your-web__dot-you" />
          <text x="210" y="210" class="cgsf-your-web__initials cgsf-your-web__initials--you">
            {{i18n "cgsf_vouch.web.you"}}
          </text>
        </svg>
      </div>

      <section class="cgsf-your-web__list">
        <h2>{{i18n "cgsf_vouch.web.vouched_title"}}</h2>
        {{#if this.vouched.length}}
          {{#each this.vouched as |neighbor|}}
            <div class="cgsf-your-web__neighbor">
              <a href="/u/{{neighbor.username}}" class="cgsf-your-web__name">
                {{neighbor.name}}
              </a>
              <DButton
                @action={{fn this.withdraw neighbor}}
                @translatedLabel={{i18n "cgsf_vouch.card.withdraw"}}
                class="btn-flat cgsf-your-web__withdraw"
              />
            </div>
          {{/each}}
        {{else}}
          <p class="cgsf-your-web__empty">{{i18n "cgsf_vouch.web.empty"}}</p>
        {{/if}}
      </section>
    </div>
  </template>
}
