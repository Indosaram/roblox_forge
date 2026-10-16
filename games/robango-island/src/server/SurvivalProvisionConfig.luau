--!strict
-- Server-only owner/consent provisioning. Membership is granted from THIS record before the
-- settlement runtime acquires its store: routing grants no membership, and an actor the record
-- does not name is refused rather than admitted.
--
-- `policy` is explicit and is never inferred from an empty owner id:
--   staging        - a real owner and its accepted invitations (a published experience).
--   developmental  - the closed Studio QA allowlist below, and only in a local Studio place.
--   unprovisioned  - nothing is provisioned, so the server refuses to start.
--
-- `actors` is the closed developmental allowlist. It is read only in a local Studio place
-- (`studio`), never in a published server.
return {
	provisionId = "development",
	policy = "developmental",
	ownerId = "",
	acceptedInvitations = {},
	actors = {},
}
