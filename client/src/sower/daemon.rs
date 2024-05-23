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
use sha2::Sha256;
use tokio::sync::mpsc;
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
            Err(e) => panic!("Failed to connect, {}", e),
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

    //async fn login(&mut self) {
    //    info!("Registering with sower");
    //    let Payload::JSONPayload { json } = self
    //        .lobby_channel
    //        .call(
    //            Event::from_string("register".to_string()),
    //            Payload::json_from_serialized(
    //                json!({ "name": &self.tree.name, "type": &self.tree.seed_type}).to_string(),
    //            )
    //            .unwrap(),
    //            Duration::from_secs(5),
    //        )
    //        .await
    //        .unwrap()
    //    else {
    //        panic!("unable to register")
    //    };
    //
    //    self.tree.id = if let JSON::Str { string, .. } = &json {
    //        info!("Received tree id {}", string);
    //        Some(string.to_string())
    //    } else {
    //        panic!("unable to parse registration response")
    //    };
    //}

    pub async fn run(&mut self) -> Result<(), std::io::Error> {
        //self.login().await;
        let (private_channel_tx, mut private_channel_rx) = mpsc::channel(1);
        let (shutdown_send, shutdown_recv) = mpsc::unbounded_channel();

        tokio::select! {
            _ = signal::ctrl_c() => {
                info!("Received shutdown");
                shutdown_send.send(true).unwrap()
            },

            _ = self.run_lobby(shutdown_recv, private_channel_tx) => {},

            //_ = async {
            //    match private_channel_rx.recv().await {
            //        Some(tree_id) => {
            //            debug!("Setting server's tree_id to {}", tree_id);
            //            self.tree.server_id = Some(tree_id)
            //        },
            //        None => shutdown_send.send(true).unwrap()
            //    };
            //    //let events = lobby_channel.events();
            //    //info!("Joining lobby {}", self.lobby_topic);
            //    //lobby_channel.join(Duration::from_secs(15)).await.unwrap();
            //    //
            //    //info!("Listening for lobby events");
            //    //loop {
            //    //    match events.event().await {
            //    //        event => debug!("{:?}", event)
            //    //    }
            //    //}
            //} => {},

            //_ = async {
            //        let until = match statuses.status().await {
            //            Ok(ChannelStatus::WaitingToRejoin { until }) => until,
            //            other => panic!("Didn't wait to rejoin after being unauthorized instead {:?}", other)
            //        };
            //} => {},

            //_ = async {
            //    info!("Starting submit loop");
            //    let mut interval = time::interval(time::Duration::from_secs(5));
            //    loop {
            //        interval.tick().await;
            //        let seeds = self.tree.seeds.clone().unwrap();
            //        let reply_payload = lobby_channel.call(
            //            Event::from_string("seed:sync".to_string()),
            //            Payload::json_from_serialized(json!({ "booted_seed": seeds.booted, "current_seed": seeds.current, "profile_seed": seeds.profile }).to_string()).unwrap(),
            //            Duration::from_secs(5)
            //        ).await;
            //
            //        match reply_payload {
            //            Ok(payload) => info!("got reply: {}", payload),
            //            Err(err) => error!("error waiting for reply: {}", err)
            //        }
            //    }
            //} => {}
        }

        info!("Closing socket");
        self.socket.disconnect().await.unwrap();

        info!("Shutdown");
        Ok(())
    }

    async fn run_lobby(
        &mut self,
        mut shutdown_rx: mpsc::UnboundedReceiver<bool>,
        private_channel_tx: mpsc::Sender<String>,
    ) {
        let events = self.lobby_channel.events();
        let lobby_topic = self.lobby_topic.clone();
        info!("Joining lobby {}", self.lobby_topic);
        self.lobby_channel
            .join(Duration::from_secs(15))
            .await
            .unwrap();

        tokio::select! {
            _ = shutdown_rx.recv() => {
                debug!("Received shutdown to run_lobby")
            },
            _ = async move {
                info!("Listening for lobby events");
                loop {
                    match events.event().await {
                        Ok(EventPayload { event, payload }) => match event {
                            Event::User {
                                user: user_event_name,
                            } => {
                                let payload = match payload {
                                    Payload::JSONPayload {
                                        json: JSON::Object { object },
                                    } => {
                                        match object.get("tree_id") {
                                            Some(JSON::Str { string: tree_id }) => {
                                                let _ = private_channel_tx.send(tree_id.to_string()).await;
                                            }
                                            Some(unknown) => error!("Unknown tree_id: {}", unknown),
                                            None => error!("No tree_id received from server"),
                                        }
                                    }
                                    Payload::JSONPayload { json } => debug!("{:?}", json),
                                    Payload::Binary { bytes } => debug!("{:?}", bytes),
                                };
                                println!(
                                    "channel {} event {} sent with payload {:#?}",
                                    lobby_topic, user_event_name, payload
                                );
                            }
                            Event::Phoenix { phoenix } => {
                                println!("channel {} {}", lobby_topic, phoenix)
                            }
                        },
                        Err(events_error) => match events_error {
                            EventsError::NoMoreEvents => break,
                            EventsError::MissedEvents { missed_event_count } => {
                                eprintln!(
                                    "{} events missed on channel {}",
                                    missed_event_count, lobby_topic
                                );
                            }
                        },
                    }
                }
            } => {
                info!("Leaving the lobby");
                self.lobby_channel.leave().await.unwrap();
            }
        }
    }
}
