# One Whop buyer, multiple Pay customers

Some applications bill organizations while the same human pays for more than one organization. Enable this explicitly:

```ruby
Pay::Whop.allow_shared_members = true
```

The default remains `false`. Install and run the new `AllowSharedWhopMembers` engine migration first. It keeps Pay's processor/member uniqueness constraint for other processors and adds a nonunique Whop member lookup index.

With sharing enabled, signed checkout metadata selects the exact Pay customer. Both customers can retain the same provider member ID; neither customer's owner, seller or environment changes. Existing customer-to-member links remain immutable. When more than one matching customer exists, an event without a signed reference is rejected instead of choosing an organization. Invalid signatures never fall back to a member lookup.

Every checkout, payment and recurring membership must preserve the adapter's `pay_customer` metadata. Use separate Whop seller/account contexts for unrelated applications. Sharing a buyer within one application does not make signatures from another Rails application valid.

Rolling back the index migration fails if shared member mappings still exist. Resolve those mappings deliberately before rollback; the migration does not merge or delete customer history.

Tests cover default identity-conflict protection, opt-in sharing, ambiguous unsigned references, forged references and attempts to change an existing customer's provider member. Checkout and transfer contract tests also verify fractional amounts at the HTTP boundary.
