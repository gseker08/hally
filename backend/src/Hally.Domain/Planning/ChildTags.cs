using Hally.Domain.Common;

namespace Hally.Domain.Planning;

/// <summary>Rules for tagging tasks and events with children.</summary>
public static class ChildTags
{
    public const int Max = 10;

    public static List<Guid> Normalize(IEnumerable<Guid>? childIds)
    {
        var ids = (childIds ?? []).Where(id => id != Guid.Empty).Distinct().ToList();
        if (ids.Count > Max)
        {
            throw new DomainException("child_tags.too_many", $"At most {Max} children can be tagged.");
        }

        return ids;
    }
}
