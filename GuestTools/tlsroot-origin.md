# TLSRoot certificate bundle

The certificate bytes come from the “Signed iOS Bundle (iOS 5+)” at https://tlsroot.litten.ca/beeg.mobileconfig.

`tlsroot-signed-ios-bundle.mobileconfig` is the downloaded CMS-signed profile. Its CMS signature was checked with .NET `SignedCms.CheckSignature(true)`. That confirms the signature matches the embedded signer certificate; the signer’s certificate chain was not validated against a trusted root. The embedded Apple Development signer certificate expired on 2026-07-08, so the profile should not be described as currently trusted by an external PKI.

The separately extracted payload is pinned by SHA-256 in `prepare_tlsroot_bundle.py`. The script includes only 32 self-issued CA certificates and deliberately excludes six Apple WWDR code-signing intermediates. It writes the deterministic archive bundled with Podium. At runtime, Podium checks the archive and every DER certificate against their pinned hashes before adding them to the guest iOS 6 TrustStore.

Installing roots may allow TLS chains to verify when the guest Safari supports the server's TLS version, cipher suite, and certificate algorithms. It cannot add newer TLS features to iOS 6.
