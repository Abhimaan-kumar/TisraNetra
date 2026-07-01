/**
 * Cloud Functions for Percive
 *
 * Trigger: when a new document is created in `help_requests`,
 * send an FCM push notification to every Volunteer user.
 */
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");

initializeApp();

/**
 * Listens for new help_requests documents and sends push notifications
 * to all volunteer users who have a valid FCM token.
 */
exports.notifyVolunteersOnHelpRequest = onDocumentCreated(
  "help_requests/{requestId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;

    const requestData = snap.data();
    const requestId = event.params.requestId;
    const clientName = requestData.clientName || "A client";

    // 1. Fetch all Volunteer users with an FCM token
    const db = getFirestore();
    const volunteersSnap = await db
      .collection("users")
      .where("userType", "==", "Volunteer")
      .get();

    if (volunteersSnap.empty) {
      console.log("No volunteer users found.");
      return;
    }

    // 2. Collect valid FCM tokens
    const tokens = [];
    volunteersSnap.forEach((doc) => {
      const data = doc.data();
      if (data.fcmToken && typeof data.fcmToken === "string") {
        tokens.push(data.fcmToken);
      }
    });

    if (tokens.length === 0) {
      console.log("No volunteer tokens found.");
      return;
    }

    console.log(`Sending notification to ${tokens.length} volunteer(s).`);

    // 3. Build the FCM message
    const message = {
      notification: {
        title: "Help Request",
        body: `${clientName} needs your help! Tap to accept.`,
      },
      data: {
        type: "help_request",
        requestId: requestId,
        clientName: clientName,
      },
      // Android-specific: high priority so notification shows immediately
      android: {
        priority: "high",
        notification: {
          channelId: "help_requests",
          sound: "default",
          clickAction: "FLUTTER_NOTIFICATION_CLICK",
        },
      },
      // APNs (iOS)
      apns: {
        payload: {
          aps: {
            alert: {
              title: "Help Request",
              body: `${clientName} needs your help! Tap to accept.`,
            },
            sound: "default",
            "content-available": 1,
          },
        },
      },
    };

    // 4. Send to each token individually (sendEachForMulticast)
    const messaging = getMessaging();
    const response = await messaging.sendEachForMulticast({
      tokens: tokens,
      notification: message.notification,
      data: message.data,
      android: message.android,
      apns: message.apns,
    });

    console.log(
      `FCM sent: ${response.successCount} success, ${response.failureCount} failures.`
    );

    // 5. Clean up invalid tokens
    const tokensToRemove = [];
    response.responses.forEach((resp, idx) => {
      if (resp.error) {
        console.error(`Error sending to token ${idx}:`, resp.error);
        const code = resp.error.code;
        if (
          code === "messaging/invalid-registration-token" ||
          code === "messaging/registration-token-not-registered"
        ) {
          tokensToRemove.push(tokens[idx]);
        }
      }
    });

    // Remove stale tokens from Firestore
    if (tokensToRemove.length > 0) {
      const batch = db.batch();
      const staleSnap = await db
        .collection("users")
        .where("fcmToken", "in", tokensToRemove)
        .get();
      staleSnap.forEach((doc) => {
        batch.update(doc.ref, { fcmToken: "" });
      });
      await batch.commit();
      console.log(`Cleaned up ${tokensToRemove.length} stale token(s).`);
    }
  }
);
