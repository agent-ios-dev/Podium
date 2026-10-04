"""Rebuild the pinned TLSRoot.litten.ca iOS 5+ root certificate bundle."""

import hashlib
import json
import plistlib
import re
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PROFILE_CMS = ROOT / "GuestTools/tlsroot-signed-ios-bundle.mobileconfig"
PROFILE_PAYLOAD = ROOT / "GuestTools/tlsroot-signed-profile.plist"
OUTPUT = ROOT / "Podium/Resources/GuestTools/tlsroot-root-certificates.zip"

# The original CMS signature was checked with .NET SignedCms.CheckSignature(true).
# Signature-only verification succeeded; Windows could not build the Apple WWDR
# chain, and the embedded Apple Development signing certificate expired 2026-07-08.
PROFILE_CMS_SHA256 = "1fdbbe4b4571ede657ce4a792434fbef94c052c043e4ef992e905d8a68ced281"
PROFILE_PAYLOAD_SHA256 = "255731b0008e1763300bbb365518280846209c73f0f6dcea82aa118783324d8d"
SIGNER_SHA1 = "0A113C3E840DAD1ABF2E9E63161C8A469DABB465"

# Only self-issued root CAs are imported. Apple WWDR intermediates carried in
# the profile are deliberately excluded; they are code-signing intermediates.
ROOT_CERTIFICATES = {
    "DigiCertGlobalRootG2.crt": "cb3ccbb76031e5e0138f8dd39a23f9de47ffc35e43c1144cea27d46a5ab1cb5f",
    "DigiCertGlobalRootG3.crt": "31ad6648f8104138c738f39ea4320133393e3a18cc02296ef97c2ac9ef6731d0",
    "DigiCertHighAssuranceEVRootCA.crt": "7431e5f4c3c1ce4690774f0b61e05440883ba9a01ed00ba6abd7806ed3b118cf",
    "GeoTrustPCA-G2.crt": "5edb7ac43b82a06a8761e8d7be4979ebf2611f7dd79bf91c1c6b566a219ed766",
    "GeoTrustPCA-G3.crt": "b478b812250df878635c2aa7ec7d155eaa625ee82916e2cd294361886cd1fbd4",
    "GeoTrustPCA.crt": "37d51006c512eaab626421f1ec8c92013fc5f82ae98ee533eb4619b8deb4d06c",
    "USERTrustECCCertificationAuthority.crt": "4ff460d54b9c86dabfbcfc5712e0400d2bed3fbc4d4fbdaa86e06adcd2a9ad7a",
    "USERTrustRSACertificationAuthority.crt": "e793c9b02fd8aa13e21c31228accb08119643b749c898964b1746d46c3d4cbd2",
    "AmazonRootCA1.cer": "8ecde6884f3d87b1125ba31ac3fcb13d7016de7f57cc904fe1cb97c6ae98196e",
    "AmazonRootCA2.cer": "1ba5b2aa8c65401a82960118f80bec4f62304d83cec4713a19c39c011ea46db4",
    "AmazonRootCA3.cer": "18ce6cfe7bf14e60b2e347b8dfe868cb31d02ebb3ada271569f50343b46db3a4",
    "AmazonRootCA4.cer": "e35d28419ed02025cfa69038cd623962458da5c695fbdea3c22b0bfb25897092",
    "AppleIncRootCertificate.cer": "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024",
    "AppleRootCA-G2.cer": "c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050",
    "AppleRootCA-G3.cer": "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179",
    "comodoECC.cer": "1793927a0614549789adce2f8f34f7f0b66d0f3ae3a3b84d21ec15dbba4fadc7",
    "comodoRSA.cer": "52f0e1c4e58ec629291b60317f074671b85d7ea80d5b07273463534b32b40234",
    "entrust_ec1_ca.cer": "bc8479e7aa80c4d5b587285e92860246034c129f2831b969b047447de54c4362",
    "entrust_g2_ca.cer": "646db48fa7794bcab4581f264ff3fad4cff7bbd24f5e8bb170d4f602b6caf828",
    "SFSRootCAG2.cer": "568d6905a2c88708a4b3025190edcfedb1974a606a13c6e5290fcb2ae63edab5",
    "isrg-root-x2.der": "69729b8e15a86efc177a57afb7171dfc64add28c2fca8cf1507e34453ccb1470",
    "isrgrootx1.der": "96bcec06264976f37460779acf28c5a7cfe8a3c0aae11a8ffcee05c0bddf08c6",
    "gsr4.crt": "b085d70b964f191a73e4af0d54ae7a0e07aafdaf9b71dd0862138ab7325a24a2",
    "Root-R3.crt": "cbb522d7b7f127ad6a0113865bdf1cd4102e7d0759af635a7cf4720dc963c53b",
    "Root-R5.crt": "179fbc148a3dd00fd24ea13458cc43bfa7f59c8182d783a513f6ebec100c8924",
    "root-r6.crt": "2cabeafe37d06ca22aba7391c0033d25982952c453647349763a3ab5ad6ccf69",
    "roote46.crt": "cbb9c44d84b8043e1050ea31a69f514955d7bfd2e2c6b49301019ad61d9f5058",
    "rootr46.crt": "4fa3126d8d3a11d1c4855a4f807cbad6cf919d3a5a88b03bea2c6372d93c40c9",
    "r1.crt": "d947432abde7b7fa90fc2e6b59101b1280e0e1c7e4e40fa3c6887fff57a7f4cf",
    "r2.crt": "8d25cd97229dbf70356bda4eb3cc734031e24cf00fafcfd32dc76eb5841c7ea8",
    "r3.crt": "34d8a73ee208d9bcdb0d956520934b4e40e69482596e8b6f73c8426b010a6f48",
    "r4.crt": "349dfa4058c5e263123b398ae795573c4e1313c83fe68f93556cd5e8031b3c7d",
}


def parse_signed_payload() -> dict:
    if hashlib.sha256(PROFILE_CMS.read_bytes()).hexdigest() != PROFILE_CMS_SHA256:
        raise ValueError("TLSRoot source profile changed; re-verify its CMS signature before updating pins")
    payload = PROFILE_PAYLOAD.read_bytes()
    if hashlib.sha256(payload).hexdigest() != PROFILE_PAYLOAD_SHA256:
        raise ValueError("The extracted TLSRoot profile payload does not match the verified signed payload")
    text = payload.decode("utf-8")
    quote = chr(34)
    text = text.replace(
        "<?xml version=1.0 encoding=utf-8?>",
        "<?xml version=" + quote + "1.0" + quote + " encoding=" + quote + "utf-8" + quote + "?>",
    )
    text = re.sub(r"<!DOCTYPE[^>]*>", "", text, count=1)
    text = text.replace("<plist version=1.0>", "<plist version=" + quote + "1.0" + quote + ">")
    profile = plistlib.loads(text.encode("utf-8"))
    if profile.get("PayloadType") != "Configuration" or len(profile.get("PayloadContent", [])) != 38:
        raise ValueError("Unexpected TLSRoot signed iOS profile")
    return profile


def main() -> None:
    profile = parse_signed_payload()
    items = {
        item.get("PayloadCertificateFileName"): item
        for item in profile["PayloadContent"]
    }
    if len(items) != 38:
        raise ValueError("The TLSRoot profile contains duplicate or unnamed certificates")
    if set(items) != set(ROOT_CERTIFICATES) | {
        "AppleWWDRCAG2.cer", "AppleWWDRCAG3.cer", "AppleWWDRCAG4.cer",
        "AppleWWDRCAG5.cer", "AppleWWDRCAG6.cer", "AppleWWDRMPCA1G1.cer",
    }:
        raise ValueError("The certificate inventory changed; review roots and intermediates before updating")

    entries: dict[str, bytes] = {}
    certificates = []
    for filename, expected_sha256 in sorted(ROOT_CERTIFICATES.items()):
        item = items[filename]
        if item.get("PayloadType") != "com.apple.security.pkcs1":
            raise ValueError(f"Unexpected payload type for {filename}")
        der = item.get("PayloadContent")
        if not isinstance(der, bytes) or hashlib.sha256(der).hexdigest() != expected_sha256:
            raise ValueError(f"Certificate fingerprint mismatch: {filename}")
        path = "certs/" + filename
        entries[path] = der
        certificates.append({
            "path": path,
            "sha256": expected_sha256,
            "displayName": item.get("PayloadDisplayName", filename),
        })

    metadata = {
        "source": "https://tlsroot.litten.ca/beeg.mobileconfig",
        "sourceProfileSHA256": PROFILE_CMS_SHA256,
        "profilePayloadSHA256": PROFILE_PAYLOAD_SHA256,
        "profileSignerSHA1": SIGNER_SHA1,
        "profileSignerValidThrough": "2026-07-08",
        "certificates": certificates,
    }
    entries["manifest.json"] = json.dumps(metadata, sort_keys=True, separators=(",", ":")).encode()
    origin = (
        "Source: https://tlsroot.litten.ca/beeg.mobileconfig\n"
        f"Signed profile SHA-256: {PROFILE_CMS_SHA256}\n"
        f"Extracted payload SHA-256: {PROFILE_PAYLOAD_SHA256}\n"
        f"CMS signer SHA-1: {SIGNER_SHA1}\n"
        "CMS signature: verified by .NET SignedCms.CheckSignature(true); certificate trust-chain validation was not performed.\n"
        "The embedded Apple Development signer certificate expired 2026-07-08.\n"
        "Included: 32 fingerprint-pinned, self-issued root CA certificates.\n"
        "Excluded: six Apple WWDR intermediate code-signing certificates.\n"
    ).encode()
    entries["ORIGIN.txt"] = origin

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(OUTPUT, "w") as archive:
        for name, data in sorted(entries.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    print(f"{OUTPUT} ({OUTPUT.stat().st_size} bytes; 32 TLS root certificates)")


if __name__ == "__main__":
    main()
