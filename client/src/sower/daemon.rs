use super::{Config, Tree};

use std::sync::Arc;
use std::time::Duration;

use hmac::{Hmac, Mac};
use jwt::SignWithKey;
use phoenix_channels_client::url::Url;
use phoenix_channels_client::{
    Channel, Event, EventPayload, EventsError, Payload, Socket, Topic, JSON,
};
use serde_derive::{Deserialize, Serialize};
use serde_json::json;
use sha2::Sha256;
use tokio::{signal, time};
use tracing::{debug, error, info};

pub struct Daemon {
    tree: Tree,
    socket: Arc<Socket>,
    lobby_channel: Arc<Channel>,
    lobby_topic: Arc<Topic>,
}

#[derive(Deserialize, Serialize)]
struct BootstrapClaim {
    name: String,
    seed_type: String,
    sub: String,
}

impl Daemon {
    pub async fn new(config: &Config) -> Self {
        let tree = Tree::new(config).await.expect("Failed to load tree");

        info!("Connecting to sower");
        let url = Url::parse_with_params(
            &tree.sower.clone().unwrap().channels_url,
            &[(
                "token",
                Self::sign_login_jwt(config.bootstrap_token.clone().unwrap(), &tree).unwrap(),
            )],
        )
        .unwrap();
        let socket = Socket::spawn(url, None).unwrap();
        match socket.connect(Duration::from_secs(10)).await {
            Ok(_) => info!("Connected"),
            Err(_) => panic!("Failed to connect"),
        }

        let topic = Topic::from_string("client:all".to_string());
        info!("Joining lobby {}", topic);
        let channel = socket.channel(topic.clone(), None).await.unwrap();
        channel.join(Duration::from_secs(15)).await.unwrap();

        Self {
            lobby_channel: channel,
            lobby_topic: topic,
            socket,
            tree,
        }
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

    async fn login(&mut self) {
        info!("Registering with sower");
        let Payload::JSONPayload { json } = self
            .lobby_channel
            .call(
                Event::from_string("register".to_string()),
                Payload::json_from_serialized(
                    json!({ "name": &self.tree.name, "type": &self.tree.seed_type}).to_string(),
                )
                .unwrap(),
                Duration::from_secs(5),
            )
            .await
            .unwrap()
        else {
            panic!("unable to register")
        };

        self.tree.id = if let JSON::Str { string, .. } = &json {
            info!("Received tree id {}", string);
            Some(string.to_string())
        } else {
            panic!("unable to parse registration response")
        };
    }

    pub async fn run(&mut self) -> Result<(), std::io::Error> {
        self.login().await;

        tokio::select! {
            _ = signal::ctrl_c() => {
                info!("Received shutdown")
            },

            _ = async {
                let events = self.lobby_channel.events();

                info!("Listening for events");
                loop {
                    match events.event().await {
                        Ok(EventPayload { event, payload }) => match event {
                            Event::User {
                                user: user_event_name,
                            } => println!(
                                "channel {} event {} sent with payload {:#?}",
                                self.lobby_topic, user_event_name, payload
                            ),
                            Event::Phoenix { phoenix } => println!("channel {} {}", self.lobby_topic, phoenix),
                        },
                        Err(events_error) => match events_error {
                            EventsError::NoMoreEvents => break,
                            EventsError::MissedEvents { missed_event_count } => {
                                eprintln!("{} events missed on channel {}", missed_event_count, self.lobby_topic);
                            }
                        },
                    }
                }
            } => {},

            _ = async {
                info!("Starting submit loop");
                let mut interval = time::interval(time::Duration::from_secs(5));
                loop {
                    interval.tick().await;
                    debug!("tick");
                    let reply_payload = self.lobby_channel.call(
                        Event::from_string("ping".to_string()),
                        Payload::json_from_serialized(json!({ "token": "ok" }).to_string()).unwrap(),
                        Duration::from_secs(5)
                    ).await;

                    match reply_payload {
                        Ok(payload) => info!("{}", payload),
                        Err(err) => error!("{}", err)
                    }
                }
            } => {}
        }

        info!("Leaving the lobby");
        self.lobby_channel.leave().await.unwrap();

        info!("Closing socket");
        self.socket.disconnect().await.unwrap();

        info!("Shutdown");
        Ok(())
    }
}
