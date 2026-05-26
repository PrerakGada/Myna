# frozen_string_literal: true

# Myna's Python HTTP daemon — chunking, extract, summarize, /synthesize.
# Installed via Homebrew so the .app cask can depend on it.
class MynaDaemon < Formula
  include Language::Python::Virtualenv

  desc "Myna's Python HTTP daemon (chunking, extract, summarize, /synthesize)"
  homepage "https://github.com/PrerakGada/myna"
  url "https://github.com/PrerakGada/myna/archive/refs/tags/v0.1.0.tar.gz"
  # release.yml does NOT bump this formula on every release — it bumps the cask
  # only. Daemon updates ride the cask's homepage release; bump this manually
  # when daemon code changes meaningfully.
  sha256 "0a8795d741efc5ff5c426e2022245e92723863d33003d7f4476ad3579c08a3f5"
  license "MIT"
  head "https://github.com/PrerakGada/myna.git", branch: "main"

  depends_on "python@3.13"
  # Rust toolchain is needed to build pydantic_core and watchfiles from source
  # (Homebrew installs PyPI resources via --no-binary :all:, so even pure-Python
  # wheels are rebuilt from sdist; Rust extensions can't bootstrap without it).
  depends_on "rust" => :build

  # The daemon needs an mlx-audio Kokoro engine on :8765. That engine is too
  # heavy to bundle via brew (multi-GB model weights, Apple-Silicon-only). We
  # document the engine install in `brew info` caveats below and skip it as a
  # dependency.

  resource "annotated-doc" do
    url "https://files.pythonhosted.org/packages/57/ba/046ceea27344560984e26a590f90bc7f4a75b06701f653222458922b558c/annotated_doc-0.0.4.tar.gz"
    sha256 "fbcda96e87e9c92ad167c2e53839e57503ecfda18804ea28102353485033faa4"
  end

  resource "annotated-types" do
    url "https://files.pythonhosted.org/packages/ee/67/531ea369ba64dcff5ec9c3402f9f51bf748cec26dde048a2f973a4eea7f5/annotated_types-0.7.0.tar.gz"
    sha256 "aff07c09a53a08bc8cfccb9c85b05f1aa9a2a6f23728d790723543408344ce89"
  end

  resource "anyio" do
    url "https://files.pythonhosted.org/packages/19/14/2c5dd9f512b66549ae92767a9c7b330ae88e1932ca57876909410251fe13/anyio-4.13.0.tar.gz"
    sha256 "334b70e641fd2221c1505b3890c69882fe4a2df910cba14d97019b90b24439dc"
  end

  resource "babel" do
    url "https://files.pythonhosted.org/packages/7d/b2/51899539b6ceeeb420d40ed3cd4b7a40519404f9baf3d4ac99dc413a834b/babel-2.18.0.tar.gz"
    sha256 "b80b99a14bd085fcacfa15c9165f651fbb3406e66cc603abf11c5750937c992d"
  end

  resource "certifi" do
    url "https://files.pythonhosted.org/packages/f3/ce/ee2ecad540810a79593028e88299baeae54d346cc7a0d94b6199988b89b1/certifi-2026.5.20.tar.gz"
    sha256 "69dea482ab64caa7b9f6aba1c6bf48bb6a5448d1c0f1b17ab42ad8c763a5344d"
  end

  resource "charset-normalizer" do
    url "https://files.pythonhosted.org/packages/e7/a1/67fe25fac3c7642725500a3f6cfe5821ad557c3abb11c9d20d12c7008d3e/charset_normalizer-3.4.7.tar.gz"
    sha256 "ae89db9e5f98a11a4bf50407d4363e7b09b31e55bc117b4f7d80aab97ba009e5"
  end

  resource "click" do
    url "https://files.pythonhosted.org/packages/9b/98/518d8e5081007684232226f475082b30087d0f585e8457db087298259f49/click-8.4.1.tar.gz"
    sha256 "918b5633eddf6b41c32d4f454bf0de810065c74e3f7dbf8ee5452f8be88d3e96"
  end

  resource "courlan" do
    url "https://files.pythonhosted.org/packages/6f/54/6d6ceeff4bed42e7a10d6064d35ee43a810e7b3e8beb4abeae8cff4713ae/courlan-1.3.2.tar.gz"
    sha256 "0b66f4db3a9c39a6e22dd247c72cfaa57d68ea660e94bb2c84ec7db8712af190"
  end

  resource "dateparser" do
    url "https://files.pythonhosted.org/packages/46/2d/a0ccdb78788064fa0dc901b8524e50615c42be1d78b78d646d0b28d09180/dateparser-1.4.0.tar.gz"
    sha256 "97a21840d5ecdf7630c584f673338a5afac5dfe84f647baf4d7e8df98f9354a4"
  end

  resource "fastapi" do
    url "https://files.pythonhosted.org/packages/81/2d/ff8d91d7b564d464629a0fd50a4489c97fcb836ac230bf3a7269232a9b1f/fastapi-0.136.3.tar.gz"
    sha256 "e487fae93ad408e6f47641ee4dfe389864fd7bec92e547ea8498fc13f43e83ab"
  end

  resource "h11" do
    url "https://files.pythonhosted.org/packages/01/ee/02a2c011bdab74c6fb3c75474d40b3052059d95df7e73351460c8588d963/h11-0.16.0.tar.gz"
    sha256 "4e35b956cf45792e4caa5885e69fba00bdbc6ffafbfa020300e549b208ee5ff1"
  end

  resource "htmldate" do
    url "https://files.pythonhosted.org/packages/9d/10/ead9dabc999f353c3aa5d0dc0835b1e355215a5ecb489a7f4ef2ddad5e33/htmldate-1.9.4.tar.gz"
    sha256 "1129063e02dd0354b74264de71e950c0c3fcee191178321418ccad2074cc8ed0"
  end

  resource "httpcore" do
    url "https://files.pythonhosted.org/packages/06/94/82699a10bca87a5556c9c59b5963f2d039dbd239f25bc2a63907a05a14cb/httpcore-1.0.9.tar.gz"
    sha256 "6e34463af53fd2ab5d807f399a9b45ea31c3dfa2276f15a2c3f00afff6e176e8"
  end

  resource "httptools" do
    url "https://files.pythonhosted.org/packages/43/e5/d471fcb0e14523fe1c3f4ba58ca52480e7bd70ad7109a3846bc75892f7fb/httptools-0.8.0.tar.gz"
    sha256 "6b2a32f18d97e16e90827d7a819ffa8dbd8cc245fc4e1fa9d1095b54ef4bd999"
  end

  resource "httpx" do
    url "https://files.pythonhosted.org/packages/b1/df/48c586a5fe32a0f01324ee087459e112ebb7224f646c0b5023f5e79e9956/httpx-0.28.1.tar.gz"
    sha256 "75e98c5f16b0f35b567856f597f06ff2270a374470a5c2392242528e3e3e42fc"
  end

  resource "idna" do
    url "https://files.pythonhosted.org/packages/1a/88/bcf9709822fe69d02c2a6a77956c98ce6ea8ca8767a9aadcedc7eb6a2390/idna-3.16.tar.gz"
    sha256 "d7a6da03db833450fca25d2358ac9ff06cd624577a4aea3a596d5c0f77b8e03d"
  end

  resource "Jinja2" do
    url "https://files.pythonhosted.org/packages/df/bf/f7da0350254c0ed7c72f3e33cef02e048281fec7ecec5f032d4aac52226b/jinja2-3.1.6.tar.gz"
    sha256 "0137fb05990d35f1275a587e9aee6d56da821fc83491a0fb838183be43f66d6d"
  end

  resource "jusText" do
    url "https://files.pythonhosted.org/packages/49/f3/45890c1b314f0d04e19c1c83d534e611513150939a7cf039664d9ab1e649/justext-3.0.2.tar.gz"
    sha256 "13496a450c44c4cd5b5a75a5efcd9996066d2a189794ea99a49949685a0beb05"
  end

  resource "lxml" do
    url "https://files.pythonhosted.org/packages/05/3b/aab6728cae887456f409b4d75e8a01856e4f04bd510de38052a47768b680/lxml-6.1.1.tar.gz"
    sha256 "ba96ae44888e0185281e937633a743ea90d5a196c6000f82565ebb0580012d40"
  end

  resource "lxml_html_clean" do
    url "https://files.pythonhosted.org/packages/0a/63/195dfdde380a84df309e3bccf4384b034b745dba43426886f7ae623b4fba/lxml_html_clean-0.4.5.tar.gz"
    sha256 "e2a4c7d5beedd17cd7b484d848a0571e54baa239a4f9df5546e3acba7f990560"
  end

  resource "MarkupSafe" do
    url "https://files.pythonhosted.org/packages/7e/99/7690b6d4034fffd95959cbe0c02de8deb3098cc577c67bb6a24fe5d7caa7/markupsafe-3.0.3.tar.gz"
    sha256 "722695808f4b6457b320fdc131280796bdceb04ab50fe1795cd540799ebe1698"
  end

  resource "pydantic" do
    url "https://files.pythonhosted.org/packages/18/a5/b60d21ac674192f8ab0ba4e9fd860690f9b4a6e51ca5df118733b487d8d6/pydantic-2.13.4.tar.gz"
    sha256 "c40756b57adaa8b1efeeced5c196f3f3b7c435f90e84ea7f443901bec8099ef6"
  end

  resource "pydantic_core" do
    url "https://files.pythonhosted.org/packages/9d/56/921726b776ace8d8f5db44c4ef961006580d91dc52b803c489fafd1aa249/pydantic_core-2.46.4.tar.gz"
    sha256 "62f875393d7f270851f20523dd2e29f082bcc82292d66db2b64ea71f64b6e1c1"
  end

  resource "python-dateutil" do
    url "https://files.pythonhosted.org/packages/66/c0/0c8b6ad9f17a802ee498c46e004a0eb49bc148f2fd230864601a86dcf6db/python-dateutil-2.9.0.post0.tar.gz"
    sha256 "37dd54208da7e1cd875388217d5e00ebd4179249f90fb72437e91a35459a0ad3"
  end

  resource "python-dotenv" do
    url "https://files.pythonhosted.org/packages/82/ed/0301aeeac3e5353ef3d94b6ec08bbcabd04a72018415dcb29e588514bba8/python_dotenv-1.2.2.tar.gz"
    sha256 "2c371a91fbd7ba082c2c1dc1f8bf89ca22564a087c2c287cd9b662adde799cf3"
  end

  resource "pytz" do
    url "https://files.pythonhosted.org/packages/ff/46/dd499ec9038423421951e4fad73051febaa13d2df82b4064f87af8b8c0c3/pytz-2026.2.tar.gz"
    sha256 "0e60b47b29f21574376f218fe21abc009894a2321ea16c6754f3cad6eb7cdd6a"
  end

  resource "PyYAML" do
    url "https://files.pythonhosted.org/packages/05/8e/961c0007c59b8dd7729d542c61a4d537767a59645b82a0b521206e1e25c2/pyyaml-6.0.3.tar.gz"
    sha256 "d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f"
  end

  resource "regex" do
    url "https://files.pythonhosted.org/packages/dc/0e/49aee608ad09480e7fd276898c99ec6192985fa331abe4eb3a986094490b/regex-2026.5.9.tar.gz"
    sha256 "a8234aa23ec39894bfe4a3f1b85616a7032481964a13ac6fc9f10de4f6fca270"
  end

  resource "six" do
    url "https://files.pythonhosted.org/packages/94/e7/b2c673351809dca68a0e064b6af791aa332cf192da575fd474ed7d6f16a2/six-1.17.0.tar.gz"
    sha256 "ff70335d468e7eb6ec65b95b99d3a2836546063f63acc5171de367e834932a81"
  end

  resource "starlette" do
    url "https://files.pythonhosted.org/packages/95/66/4d20cdf39a8d6a51e663b7038e3b828ff211d3891a43a713fe7e4643f3a8/starlette-1.1.0.tar.gz"
    sha256 "e83c7fe0ddecd8719c5b840080325aec0260acec86e9832899e377b91d65e90f"
  end

  resource "tld" do
    url "https://files.pythonhosted.org/packages/5c/5d/76b4383ac4e5b5e254e50c09807b3e13820bed6d6c11cd540264988d6802/tld-0.13.2.tar.gz"
    sha256 "d983fa92b9d717400742fca844e29d5e18271079c7bcfabf66d01b39b4a14345"
  end

  resource "trafilatura" do
    url "https://files.pythonhosted.org/packages/06/25/e3ebeefdebfdfae8c4a4396f5a6ea51fc6fa0831d63ce338e5090a8003dc/trafilatura-2.0.0.tar.gz"
    sha256 "ceb7094a6ecc97e72fea73c7dba36714c5c5b577b6470e4520dca893706d6247"
  end

  resource "typing-inspection" do
    url "https://files.pythonhosted.org/packages/55/e3/70399cb7dd41c10ac53367ae42139cf4b1ca5f36bb3dc6c9d33acdb43655/typing_inspection-0.4.2.tar.gz"
    sha256 "ba561c48a67c5958007083d386c3295464928b01faa735ab8547c5692e87f464"
  end

  resource "typing_extensions" do
    url "https://files.pythonhosted.org/packages/72/94/1a15dd82efb362ac84269196e94cf00f187f7ed21c242792a923cdb1c61f/typing_extensions-4.15.0.tar.gz"
    sha256 "0cea48d173cc12fa28ecabc3b837ea3cf6f38c6d1136f85cbaaf598984861466"
  end

  resource "tzlocal" do
    url "https://files.pythonhosted.org/packages/8b/2e/c14812d3d4d9cd1773c6be938f89e5735a1f11a9f184ac3639b93cef35d5/tzlocal-5.3.1.tar.gz"
    sha256 "cceffc7edecefea1f595541dbd6e990cb1ea3d19bf01b2809f362a03dd7921fd"
  end

  resource "urllib3" do
    url "https://files.pythonhosted.org/packages/53/0c/06f8b233b8fd13b9e5ee11424ef85419ba0d8ba0b3138bf360be2ff56953/urllib3-2.7.0.tar.gz"
    sha256 "231e0ec3b63ceb14667c67be60f2f2c40a518cb38b03af60abc813da26505f4c"
  end

  resource "uvicorn" do
    url "https://files.pythonhosted.org/packages/e6/bf/f6544ba992ddb9a6077343a576f9844f7f8f06ab819aefd00206e9255f18/uvicorn-0.48.0.tar.gz"
    sha256 "a5504207195d08c2511bf9125ede5ac4a4b71725d519e758d01dcf0bc2d31c37"
  end

  resource "uvloop" do
    url "https://files.pythonhosted.org/packages/06/f0/18d39dbd1971d6d62c4629cc7fa67f74821b0dc1f5a77af43719de7936a7/uvloop-0.22.1.tar.gz"
    sha256 "6c84bae345b9147082b17371e3dd5d42775bddce91f885499017f4607fdaf39f"
  end

  resource "watchfiles" do
    url "https://files.pythonhosted.org/packages/cd/41/5e1a4bb12aac5f1493fa1bdc11154eca3b258ca4eba65d39c473fe19d8e9/watchfiles-1.2.0.tar.gz"
    sha256 "c995fba777f1ea992f090f9236e9284cf7a5d1a0130dd5a3d82c598cacd76838"
  end

  resource "websockets" do
    url "https://files.pythonhosted.org/packages/04/24/4b2031d72e840ce4c1ccb255f693b15c334757fc50023e4db9537080b8c4/websockets-16.0.tar.gz"
    sha256 "5f6261a5e56e8d5c42a4497b364ea24d94d9563e8fbd44e78ac40879c60179b5"
  end


  def install
    # The repo is a monorepo; daemon/ holds the Python package.
    #
    # virtualenv_install_with_resources is hard-coded to use `buildpath`
    # (the extraction root), so we can't use it directly here — pyproject.toml
    # lives at daemon/pyproject.toml, not at the root.
    #
    # Pattern: create the venv, install declared `resource` blocks (which are
    # all of daemon's PyPI deps + their transitive deps, pinned + sha-locked
    # for reproducibility), then pip_install_and_link the daemon subdir for
    # our own package. Homebrew's pip_install_and_link enforces --no-deps,
    # which is exactly what we want since deps came from `resources`.
    venv = virtualenv_create(libexec, "python3.13")
    venv.pip_install resources
    venv.pip_install_and_link buildpath/"daemon"

    # Convenience symlink so users can run `myna-daemon` (matches the LaunchAgent).
    (bin/"myna-daemon").write <<~SH
      #!/bin/bash
      exec "#{libexec}/bin/python" -m myna "$@"
    SH
    chmod 0755, bin/"myna-daemon"

    # Default config (only written if not present — install logic mirrors install.sh).
    (etc/"myna").mkpath
    keybindings = etc/"myna/keybindings.json"
    return if keybindings.exist?

    keybindings.write <<~JSON
      {
        "speak_selection_full":    { "mods": ["cmd","alt","shift"], "key": "s" },
        "speak_selection_summary": { "mods": ["cmd","alt","shift"], "key": "a" },
        "read_chrome_article":     { "mods": ["cmd","alt","shift"], "key": "r" },
        "pause_resume":            { "mods": ["cmd","alt","shift"], "key": "space" },
        "stop":                    { "mods": ["cmd","alt","shift"], "key": "." }
      }
    JSON
  end

  # Auto-managed LaunchAgent via Homebrew's `brew services` interface. Users
  # can `brew services start myna-daemon` once and forget.
  service do
    run [opt_bin/"myna-daemon"]
    keep_alive true
    log_path   var/"log/myna-daemon.log"
    error_log_path var/"log/myna-daemon.log"
    working_dir var/"myna"
    environment_variables MYNA_CONFIG_DIR: etc/"myna"
  end

  def caveats
    <<~EOS
      Myna's daemon is now installed.

      Start it (and have it relaunch on boot) with:
        brew services start myna-daemon

      The daemon expects an mlx-audio Kokoro TTS engine on http://127.0.0.1:8765.
      That engine is too heavy to bundle via brew. Install it yourself with:

        python3.13 -m venv ~/.venvs/mlx-audio
        ~/.venvs/mlx-audio/bin/pip install mlx-audio

      Then run the engine (or wrap it in your own LaunchAgent):
        ~/.venvs/mlx-audio/bin/python -m mlx_audio.server --port 8765

      Config lives in #{etc}/myna/.
      Logs:     #{var}/log/myna-daemon.log
    EOS
  end

  test do
    # The package exposes a `myna` console-script that responds to --help.
    assert_match "usage", shell_output("#{bin}/myna-daemon --help 2>&1")
  end
end
