import Config

if config_env() != :test do
  SowerCli.Config.load()
end
