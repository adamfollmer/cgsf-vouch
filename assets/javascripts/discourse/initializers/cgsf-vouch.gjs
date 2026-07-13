import { withPluginApi } from "discourse/lib/plugin-api";
import { i18n } from "discourse-i18n";
import VouchCardInfo from "../components/vouch-card-info";

export default {
  name: "cgsf-vouch",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");
    if (!siteSettings.vouch_enabled) {
      return;
    }

    withPluginApi((api) => {
      if (!api.getCurrentUser()) {
        return;
      }

      api.renderInOutlet("user-card-metadata", VouchCardInfo);

      api.registerNotificationTypeRenderer(
        "vouch_offer",
        (NotificationItemBase) => {
          return class extends NotificationItemBase {
            get linkHref() {
              return "/your-web";
            }

            get icon() {
              return "handshake";
            }

            get label() {
              return this.notification.data.display_name;
            }

            get description() {
              return i18n("cgsf_vouch.notifications.offer");
            }
          };
        }
      );

      api.registerNotificationTypeRenderer(
        "vouch_accepted",
        (NotificationItemBase) => {
          return class extends NotificationItemBase {
            get linkHref() {
              return "/your-web";
            }

            get icon() {
              return "handshake";
            }

            get label() {
              return this.notification.data.display_name;
            }

            get description() {
              return i18n("cgsf_vouch.notifications.accepted");
            }
          };
        }
      );
    });
  },
};
