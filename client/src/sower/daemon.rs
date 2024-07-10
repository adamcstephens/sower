use super::{Config, Sower, Tree};

use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use hmac::{Hmac, Mac};
use jwt::SignWithKey;
use phoenix_channels_client::url::Url;
use phoenix_channels_client::{Event, EventPayload, EventsError, Payload, Socket, Topic, JSON};
use serde_derive::{Deserialize, Serialize};
use sha2::Sha256;
use tokio::signal;
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

pub struct Daemon {
    tree: Tree,
    socket: Arc<Socket>,
}

#[derive(Deserialize, Serialize)]
struct BootstrapClaim {
    name: String,
    seed_type: String,
    sub: String,
}

impl Daemon {
    pub async fn new(config: &Config, sower: &Sower) -> Self {
        let tree = Tree::new(config, sower).await.expect("Failed to load tree");

        info!("Connecting to sower");
        let url = Url::parse_with_params(
            &tree.sower.clone().unwrap().channels_url,
            &[(
                "token",
                Self::sign_login_jwt(
                    config
                        .bootstrap_token
                        .clone()
                        .expect("No bootstrap token found"),
                    &tree,
                )
                .unwrap(),
            )],
        )
        .unwrap();
        let socket = Socket::spawn(url, None).unwrap();
        match socket.connect(Duration::from_secs(10)).await {
            Ok(_) => info!("Connected"),
            Err(e) => panic!("Failed to connect, {}", e),
        }

        Self { socket, tree }
    }

    fn sign_login_jwt(key: String, tree: &Tree) -> Result<String, jwt::Error> {
        let key: Hmac<Sha256> = Hmac::new_from_slice(key.as_bytes())?;
        let claim = BootstrapClaim {
            name: tree.name.clone(),
            seed_type: tree.seed_type.to_string(),
            sub: "client bootstrap".to_string(),
        };
        let jwt = claim.sign_with_key(&key)?;

        Ok(jwt)
    }

    pub async fn run(&mut self) -> Result<(), anyhow::Error> {
        let (private_channel_tx, mut private_channel_rx) = mpsc::channel(1);
        let (shutdown_send, mut shutdown_recv) = mpsc::unbounded_channel();

        tokio::select! {
            _ = signal::ctrl_c() => {
                shutdown_send.send(true).unwrap()
            },

            _ = shutdown_recv.recv() => {
                info!("Received shutdown");
            },

            _ = Self::run_lobby(self.socket.clone(), private_channel_tx) => {},

            _ = async {
                let tree_id = match private_channel_rx.recv().await {
                    Some(tree_id) => {
                        debug!("Setting server's tree_id to {}", tree_id);
                         Some(tree_id)
                    },
                    None => {
                        error!("Failed to discover tree:id");
                        shutdown_send.send(true).unwrap();
                        None
                    }
                };

                self.tree.server_id.clone_from(&tree_id);

                Self::run_private_channel(self.socket.clone(), tree_id.unwrap()).await

            } => {},
        }

        info!("Closing socket");
        self.socket.disconnect().await.unwrap();

        info!("Shutdown");
        Ok(())
    }

    async fn run_lobby(socket: Arc<Socket>, private_channel_tx: mpsc::Sender<String>) {
        let topic = Topic::from_string("client:all".to_string());
        debug!("Joining channel {}", topic);
        let channel = socket.channel(topic.clone(), None).await.unwrap();
        channel.join(Duration::from_secs(15)).await.unwrap();
        info!("Joined channel {}", topic);

        let events = channel.events();
        let topic = topic.clone();

        loop {
            match events.event().await {
                Ok(EventPayload { event, payload }) => match event {
                    Event::User { .. } => {
                        match payload {
                            Payload::JSONPayload {
                                json: JSON::Object { object },
                            } => match object.get("tree_id") {
                                Some(JSON::Str { string: tree_id }) => {
                                    let _ = private_channel_tx.send(tree_id.to_string()).await;
                                    continue;
                                }
                                Some(unknown) => error!("Unknown tree_id: {}", unknown),
                                None => error!("No tree_id received from server"),
                            },
                            Payload::JSONPayload { json } => {
                                debug!("[{}] unknown event {:?}", topic, json)
                            }
                            Payload::Binary { bytes } => {
                                debug!("[{}] unknown event {:?}", topic, bytes)
                            }
                        };
                    }
                    Event::Phoenix { phoenix } => {
                        debug!("[{}] unknown phoenix event {}", topic, phoenix)
                    }
                },
                Err(events_error) => match events_error {
                    EventsError::NoMoreEvents => break,
                    EventsError::MissedEvents { missed_event_count } => {
                        warn!("[{}] events missed: {}", topic, missed_event_count);
                    }
                },
            }
        }
    }

    async fn run_private_channel(socket: Arc<Socket>, tree_id: String) -> Result<()> {
        let topic = Topic::from_string(format!("client:{}", tree_id));
        debug!("Joining channel {}", topic);
        let channel = socket.channel(topic.clone(), None).await?;
        channel
            .join(Duration::from_secs(15))
            .await
            .with_context(|| format!("Failed to join channel {}", topic))
            .unwrap();
        info!("Joined channel {}", topic);

        let events = channel.events();

        info!("Listening for private events");
        loop {
            let event = events.event().await;
            debug!("{:?}", event)
        }
    }
}
