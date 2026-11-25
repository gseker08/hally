using Hally.Domain.Assistant;
using Hally.Domain.Billing;
using Hally.Domain.Capture;
using Hally.Domain.Common;
using Hally.Domain.Duties;
using Hally.Domain.Expenses;
using Hally.Domain.Families;
using Hally.Domain.Feeding;
using Hally.Domain.Habits;
using Hally.Domain.Health;
using Hally.Domain.Messaging;
using Hally.Domain.Notifications;
using Hally.Domain.Planning;
using Hally.Domain.Points;
using Hally.Domain.ScreenTime;
using Hally.Domain.Sharing;
using Hally.Domain.Shopping;
using Hally.Domain.Sleep;
using Hally.Domain.Study;
using Hally.Domain.Users;
using Hally.Infrastructure.Analytics;
using Microsoft.EntityFrameworkCore;

namespace Hally.Infrastructure.Persistence;

public class HallyDbContext(DbContextOptions<HallyDbContext> options) : DbContext(options)
{
    public DbSet<User> Users => Set<User>();
    public DbSet<ExternalLogin> ExternalLogins => Set<ExternalLogin>();
    public DbSet<RefreshToken> RefreshTokens => Set<RefreshToken>();
    public DbSet<Family> Families => Set<Family>();
    public DbSet<FamilyMember> FamilyMembers => Set<FamilyMember>();
    public DbSet<Child> Children => Set<Child>();
    public DbSet<Invitation> Invitations => Set<Invitation>();
    public DbSet<IdempotencyRecord> IdempotencyRecords => Set<IdempotencyRecord>();
    public DbSet<AnalyticsEvent> AnalyticsEvents => Set<AnalyticsEvent>();
    public DbSet<FamilyTask> Tasks => Set<FamilyTask>();
    public DbSet<CalendarEvent> Events => Set<CalendarEvent>();
    public DbSet<Capture> Captures => Set<Capture>();
    public DbSet<Proposal> Proposals => Set<Proposal>();
    public DbSet<AuditEntry> AuditEntries => Set<AuditEntry>();
    public DbSet<Reminder> Reminders => Set<Reminder>();
    public DbSet<Device> Devices => Set<Device>();
    public DbSet<Notification> Notifications => Set<Notification>();
    public DbSet<ShareLink> ShareLinks => Set<ShareLink>();
    public DbSet<Conversation> Conversations => Set<Conversation>();
    public DbSet<ChatMessage> ChatMessages => Set<ChatMessage>();
    public DbSet<Subscription> Subscriptions => Set<Subscription>();
    public DbSet<MessageThread> MessageThreads => Set<MessageThread>();
    public DbSet<FamilyMessage> FamilyMessages => Set<FamilyMessage>();
    public DbSet<MessageReadState> MessageReadStates => Set<MessageReadState>();
    public DbSet<ScreenTimeSession> ScreenTimeSessions => Set<ScreenTimeSession>();
    public DbSet<Medication> Medications => Set<Medication>();
    public DbSet<MedicationDose> MedicationDoses => Set<MedicationDose>();
    public DbSet<ShoppingItem> ShoppingItems => Set<ShoppingItem>();
    public DbSet<SleepEntry> SleepEntries => Set<SleepEntry>();
    public DbSet<FeedingEntry> FeedingEntries => Set<FeedingEntry>();
    public DbSet<StudySession> StudySessions => Set<StudySession>();
    public DbSet<Chore> Chores => Set<Chore>();
    public DbSet<Reward> Rewards => Set<Reward>();
    public DbSet<PointEntry> PointEntries => Set<PointEntry>();
    public DbSet<Habit> Habits => Set<Habit>();
    public DbSet<HabitCheck> HabitChecks => Set<HabitCheck>();
    public DbSet<DutyRule> DutyRules => Set<DutyRule>();
    public DbSet<DutyOverride> DutyOverrides => Set<DutyOverride>();
    public DbSet<DutyDone> DutyDones => Set<DutyDone>();
    public DbSet<Expense> Expenses => Set<Expense>();
    public DbSet<Settlement> Settlements => Set<Settlement>();
    public DbSet<HealthProfile> HealthProfiles => Set<HealthProfile>();
    public DbSet<VaccineRecord> Vaccines => Set<VaccineRecord>();
    public DbSet<GrowthMeasurement> GrowthMeasurements => Set<GrowthMeasurement>();
    public DbSet<HealthAppointment> HealthAppointments => Set<HealthAppointment>();

    protected override void OnModelCreating(ModelBuilder b)
    {
        b.Entity<User>(e =>
        {
            e.Property(x => x.Email).HasMaxLength(320).IsRequired();
            e.Property(x => x.DisplayName).HasMaxLength(80).IsRequired();
            e.Property(x => x.Locale).HasMaxLength(5).IsRequired();
            e.Property(x => x.EveningPrepEnabled).HasDefaultValue(true);
            e.Property(x => x.EveningPrepHour).HasDefaultValue(20);
            e.HasIndex(x => x.Email);
            e.HasMany(x => x.Logins).WithOne().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
            e.Navigation(x => x.Logins).UsePropertyAccessMode(PropertyAccessMode.Field);
        });

        b.Entity<ExternalLogin>(e =>
        {
            e.Property(x => x.Provider).HasMaxLength(20).IsRequired();
            e.Property(x => x.Subject).HasMaxLength(255).IsRequired();
            e.HasIndex(x => new { x.Provider, x.Subject }).IsUnique();
        });

        b.Entity<RefreshToken>(e =>
        {
            e.Property(x => x.TokenHash).HasMaxLength(64).IsRequired();
            e.HasIndex(x => x.TokenHash).IsUnique();
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<Family>(e =>
        {
            e.Property(x => x.Name).HasMaxLength(80).IsRequired();
            e.Property(x => x.TimeZoneId).HasMaxLength(64).IsRequired();
            e.HasMany(x => x.Members).WithOne().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasMany(x => x.Children).WithOne().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.Navigation(x => x.Members).UsePropertyAccessMode(PropertyAccessMode.Field);
            e.Navigation(x => x.Children).UsePropertyAccessMode(PropertyAccessMode.Field);
        });

        b.Entity<FamilyMember>(e =>
        {
            e.Property(x => x.Role).HasConversion<string>().HasMaxLength(20);
            e.Property(x => x.ChildIds).HasDefaultValueSql("'{}'::uuid[]");
            e.HasIndex(x => new { x.FamilyId, x.UserId }).IsUnique();
            e.HasIndex(x => x.UserId);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<Child>(e =>
        {
            e.Property(x => x.FirstName).HasMaxLength(40).IsRequired();
            e.Property(x => x.Color).HasMaxLength(16).IsRequired().HasDefaultValue("sky");
            e.Property(x => x.PhotoKey).HasMaxLength(120);
            e.Property(x => x.PhotoContentType).HasMaxLength(40);
        });

        b.Entity<Invitation>(e =>
        {
            e.Property(x => x.TokenHash).HasMaxLength(64).IsRequired();
            e.Property(x => x.Role).HasConversion<string>().HasMaxLength(20);
            e.Property(x => x.ChildIds).HasDefaultValueSql("'{}'::uuid[]");
            e.HasIndex(x => x.TokenHash).IsUnique();
            e.HasOne(x => x.Family).WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<IdempotencyRecord>(e =>
        {
            e.HasKey(x => new { x.Scope, x.Key });
            e.Property(x => x.Scope).HasMaxLength(64);
            e.Property(x => x.Key).HasMaxLength(100);
            e.Property(x => x.RequestHash).HasMaxLength(64).IsRequired();
            e.Property(x => x.ResponseBody).HasColumnType("jsonb");
        });

        b.Entity<AnalyticsEvent>(e =>
        {
            e.Property(x => x.Name).HasMaxLength(64).IsRequired();
            e.Property(x => x.Properties).HasColumnType("jsonb");
            e.HasIndex(x => new { x.Name, x.OccurredAt });
            e.HasIndex(x => new { x.FamilyId, x.OccurredAt });
        });

        b.Entity<FamilyTask>(e =>
        {
            e.ToTable("tasks");
            e.Property(x => x.Title).HasMaxLength(200).IsRequired();
            e.Property(x => x.Notes).HasMaxLength(2000);
            e.Property(x => x.State).HasConversion<string>().HasMaxLength(20);
            e.Property(x => x.ChildIds).HasDefaultValueSql("'{}'::uuid[]");
            e.HasIndex(x => new { x.FamilyId, x.State, x.DueAt });
            e.HasIndex(x => x.SourceProposalId).IsUnique();
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<CalendarEvent>(e =>
        {
            e.ToTable("events");
            e.Property(x => x.Title).HasMaxLength(200).IsRequired();
            e.Property(x => x.Location).HasMaxLength(200);
            e.Ignore(x => x.EffectiveEnd);
            e.Ignore(x => x.SeriesStartsAt);
            e.Property(x => x.Repeat).HasConversion<string>().HasMaxLength(16);
            e.Property(x => x.ChildIds).HasDefaultValueSql("'{}'::uuid[]");
            e.HasIndex(x => new { x.FamilyId, x.StartsAt });
            e.HasIndex(x => x.SourceProposalId).IsUnique();
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<Capture>(e =>
        {
            e.Property(x => x.Source).HasConversion<string>().HasMaxLength(20);
            e.Property(x => x.Status).HasConversion<string>().HasMaxLength(20);
            e.Property(x => x.Text).HasMaxLength(20000);
            e.Property(x => x.StorageKey).HasMaxLength(200);
            e.Property(x => x.ContentType).HasMaxLength(100);
            e.Property(x => x.FailureCode).HasMaxLength(64);
            e.Property(x => x.Summary).HasMaxLength(500);
            e.HasIndex(x => new { x.FamilyId, x.CreatedAt });
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<Proposal>(e =>
        {
            e.Property(x => x.Kind).HasConversion<string>().HasMaxLength(20);
            e.Property(x => x.Status).HasConversion<string>().HasMaxLength(20);
            e.Property(x => x.Payload).HasColumnType("jsonb").IsRequired();
            e.Property(x => x.Fingerprint).HasMaxLength(64).IsRequired();
            e.Property(x => x.Version).IsRowVersion();
            e.HasIndex(x => new { x.FamilyId, x.Status });
            e.HasIndex(x => new { x.FamilyId, x.Fingerprint });
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<Capture>().WithMany().HasForeignKey(x => x.CaptureId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<AuditEntry>(e =>
        {
            e.ToTable("audit_log");
            e.Property(x => x.Action).HasMaxLength(64).IsRequired();
            e.Property(x => x.EntityType).HasMaxLength(64).IsRequired();
            e.Property(x => x.Data).HasColumnType("jsonb");
            e.HasIndex(x => new { x.FamilyId, x.At });
        });

        b.Entity<Reminder>(e =>
        {
            e.Property(x => x.Target).HasConversion<string>().HasMaxLength(20);
            e.Property(x => x.Status).HasConversion<string>().HasMaxLength(20);
            e.HasIndex(x => new { x.Status, x.FireAt });
            e.HasIndex(x => new { x.FamilyId, x.TargetId });
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<Device>(e =>
        {
            e.Property(x => x.Platform).HasMaxLength(10).IsRequired();
            e.Property(x => x.Token).HasMaxLength(512).IsRequired();
            e.HasIndex(x => x.Token).IsUnique();
            e.HasIndex(x => x.UserId);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<Notification>(e =>
        {
            e.Property(x => x.Kind).HasConversion<string>().HasMaxLength(20);
            e.Property(x => x.TargetKind).HasConversion<string>().HasMaxLength(20);
            e.Property(x => x.Title).HasMaxLength(200).IsRequired();
            e.Property(x => x.Body).HasMaxLength(1000).IsRequired();
            e.Property(x => x.DedupKey).HasMaxLength(120).IsRequired();
            e.HasIndex(x => x.DedupKey).IsUnique();
            e.HasIndex(x => new { x.UserId, x.CreatedAt });
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<ShareLink>(e =>
        {
            e.Property(x => x.Kind).HasConversion<string>().HasMaxLength(20);
            e.Property(x => x.TokenHash).HasMaxLength(64).IsRequired();
            e.HasIndex(x => x.TokenHash).IsUnique();
            e.HasIndex(x => new { x.FamilyId, x.ExpiresAt });
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<Conversation>(e =>
        {
            e.Property(x => x.Title).HasMaxLength(80);
            e.HasIndex(x => new { x.FamilyId, x.UserId, x.UpdatedAt });
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<ChatMessage>(e =>
        {
            e.Property(x => x.Role).HasConversion<string>().HasMaxLength(20);
            e.Property(x => x.Content).HasMaxLength(ChatMessage.MaxLength).IsRequired();
            e.Property(x => x.ProposalIds).HasMaxLength(1000);
            e.HasIndex(x => new { x.ConversationId, x.CreatedAt });
            e.HasIndex(x => new { x.FamilyId, x.CreatedAt });
            e.HasOne<Conversation>().WithMany().HasForeignKey(x => x.ConversationId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<Subscription>(e =>
        {
            e.Property(x => x.Source).HasConversion<string>().HasMaxLength(20);
            e.Property(x => x.ProductId).HasMaxLength(100);
            e.Property(x => x.StoreReference).HasMaxLength(1000);
            e.HasIndex(x => x.FamilyId).IsUnique();
            e.HasIndex(x => new { x.Source, x.StoreReference });
            e.HasIndex(x => x.TrialStartedByUserId);
            e.HasIndex(x => x.ExpiresAt);
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<MessageThread>(e =>
        {
            e.Property(x => x.Kind).HasConversion<string>().HasMaxLength(10);
            e.Property(x => x.Key).HasMaxLength(80).IsRequired();
            e.HasIndex(x => new { x.FamilyId, x.Key }).IsUnique();
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<FamilyMessage>(e =>
        {
            e.ToTable("family_messages");
            e.Property(x => x.Body).HasMaxLength(FamilyMessage.MaxLength).IsRequired();
            e.Property(x => x.PhotoKey).HasMaxLength(120);
            e.Property(x => x.PhotoContentType).HasMaxLength(40);
            e.HasIndex(x => new { x.ThreadId, x.CreatedAt });
            e.HasOne<MessageThread>().WithMany().HasForeignKey(x => x.ThreadId).OnDelete(DeleteBehavior.Cascade);
            // Deleting an account removes the person's messages too (right to erasure).
            e.HasOne<User>().WithMany().HasForeignKey(x => x.SenderUserId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<FamilyTask>().WithMany().HasForeignKey(x => x.TaskId).OnDelete(DeleteBehavior.SetNull);
            e.HasOne<CalendarEvent>().WithMany().HasForeignKey(x => x.EventId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<MessageReadState>(e =>
        {
            e.HasKey(x => new { x.ThreadId, x.UserId });
            e.HasOne<MessageThread>().WithMany().HasForeignKey(x => x.ThreadId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<ScreenTimeSession>(e =>
        {
            e.HasIndex(x => new { x.ChildId, x.StartedAt });
            // At most one running timer per child, even when both parents press Start at the same moment.
            e.HasIndex(x => x.ChildId).IsUnique().HasFilter("ended_at IS NULL").HasDatabaseName("ix_screen_time_sessions_running");
            e.HasIndex(x => x.EndedAt).HasFilter("ended_at IS NULL").HasDatabaseName("ix_screen_time_sessions_open");
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<Child>().WithMany().HasForeignKey(x => x.ChildId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.StartedByUserId).OnDelete(DeleteBehavior.SetNull);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.EndedByUserId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<Medication>(e =>
        {
            e.Property(x => x.Name).HasMaxLength(60).IsRequired();
            e.Property(x => x.Dose).HasMaxLength(40);
            e.Property(x => x.Notes).HasMaxLength(300);
            e.HasIndex(x => new { x.FamilyId, x.Active });
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<Child>().WithMany().HasForeignKey(x => x.ChildId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.CreatedByUserId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<MedicationDose>(e =>
        {
            e.Property(x => x.Note).HasMaxLength(200);
            e.HasIndex(x => new { x.MedicationId, x.GivenAt });
            e.HasIndex(x => new { x.FamilyId, x.GivenAt });
            e.HasOne<Medication>().WithMany().HasForeignKey(x => x.MedicationId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.GivenByUserId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<ShoppingItem>(e =>
        {
            e.Property(x => x.Text).HasMaxLength(ShoppingItem.MaxTextLength).IsRequired();
            e.Property(x => x.Quantity).HasMaxLength(ShoppingItem.MaxQuantityLength);
            e.HasIndex(x => new { x.FamilyId, x.CheckedAt });
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.AddedByUserId).OnDelete(DeleteBehavior.SetNull);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.CheckedByUserId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<SleepEntry>(e =>
        {
            e.Property(x => x.Kind).HasConversion<string>().HasMaxLength(10);
            e.Property(x => x.Note).HasMaxLength(200);
            e.HasIndex(x => new { x.ChildId, x.StartedAt });
            // One open sleep per child, even when both parents tap "asleep" at once.
            e.HasIndex(x => x.ChildId).IsUnique().HasFilter("ended_at IS NULL").HasDatabaseName("ix_sleep_entries_open");
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<Child>().WithMany().HasForeignKey(x => x.ChildId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.StartedByUserId).OnDelete(DeleteBehavior.SetNull);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.EndedByUserId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<Expense>(e =>
        {
            e.Property(x => x.Title).HasMaxLength(80);
            e.Property(x => x.Note).HasMaxLength(200);
            e.Property(x => x.Amount).HasPrecision(12, 2);
            e.Property(x => x.Category).HasConversion<string>().HasMaxLength(12);
            e.HasIndex(x => new { x.FamilyId, x.Date });
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<Child>().WithMany().HasForeignKey(x => x.ChildId).OnDelete(DeleteBehavior.SetNull);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.CreatedByUserId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<HealthProfile>(e =>
        {
            e.Property(x => x.BloodType).HasMaxLength(4);
            e.Property(x => x.Allergies).HasMaxLength(300);
            e.Property(x => x.Conditions).HasMaxLength(300);
            e.Property(x => x.Notes).HasMaxLength(300);
            e.Property(x => x.DoctorName).HasMaxLength(60);
            e.Property(x => x.DoctorPhone).HasMaxLength(30);
            e.HasIndex(x => x.ChildId).IsUnique();
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<Child>().WithMany().HasForeignKey(x => x.ChildId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<VaccineRecord>(e =>
        {
            e.ToTable("vaccines");
            e.Property(x => x.Name).HasMaxLength(60);
            e.Property(x => x.Note).HasMaxLength(200);
            e.Ignore(x => x.IsGiven);
            e.HasIndex(x => x.ChildId);
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<Child>().WithMany().HasForeignKey(x => x.ChildId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.CreatedByUserId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<GrowthMeasurement>(e =>
        {
            e.Property(x => x.HeightCm).HasPrecision(5, 1);
            e.Property(x => x.WeightKg).HasPrecision(6, 2);
            e.Property(x => x.HeadCm).HasPrecision(4, 1);
            e.HasIndex(x => new { x.ChildId, x.MeasuredOn });
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<Child>().WithMany().HasForeignKey(x => x.ChildId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.CreatedByUserId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<HealthAppointment>(e =>
        {
            e.Property(x => x.Doctor).HasMaxLength(60);
            e.HasIndex(x => x.EventId).IsUnique();
            e.HasIndex(x => x.ChildId);
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<Child>().WithMany().HasForeignKey(x => x.ChildId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<CalendarEvent>().WithMany().HasForeignKey(x => x.EventId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<Settlement>(e =>
        {
            e.Property(x => x.Amount).HasPrecision(12, 2);
            e.HasIndex(x => new { x.FamilyId, x.Date });
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<DutyRule>(e =>
        {
            e.Property(x => x.Kind).HasConversion<string>().HasMaxLength(10);
            e.Property(x => x.AssigneeName).HasMaxLength(40);
            e.HasIndex(x => new { x.FamilyId, x.Weekday, x.Kind }).IsUnique();
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.AssigneeUserId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<DutyOverride>(e =>
        {
            e.Property(x => x.Kind).HasConversion<string>().HasMaxLength(10);
            e.Property(x => x.AssigneeName).HasMaxLength(40);
            e.HasIndex(x => new { x.FamilyId, x.Date, x.Kind }).IsUnique();
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.AssigneeUserId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<DutyDone>(e =>
        {
            e.Property(x => x.Kind).HasConversion<string>().HasMaxLength(10);
            e.HasIndex(x => new { x.FamilyId, x.Date, x.Kind }).IsUnique();
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.ByUserId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<Habit>(e =>
        {
            e.Property(x => x.Title).HasMaxLength(60);
            e.HasIndex(x => x.FamilyId);
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<Child>().WithMany().HasForeignKey(x => x.ChildId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<HabitCheck>(e =>
        {
            // Once per habit per day, even when both parents tap it.
            e.HasIndex(x => new { x.HabitId, x.Day }).IsUnique();
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<Habit>().WithMany().HasForeignKey(x => x.HabitId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.ByUserId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<Chore>(e =>
        {
            e.Property(x => x.Title).HasMaxLength(60);
            e.HasIndex(x => x.FamilyId);
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<Child>().WithMany().HasForeignKey(x => x.ChildId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<Reward>(e =>
        {
            e.Property(x => x.Title).HasMaxLength(60);
            e.HasIndex(x => x.FamilyId);
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<PointEntry>(e =>
        {
            e.Property(x => x.Kind).HasConversion<string>().HasMaxLength(10);
            e.Property(x => x.Title).HasMaxLength(60);
            e.HasIndex(x => new { x.ChildId, x.CreatedAt });
            // A chore counts once per child per day, even when both parents tick it.
            e.HasIndex(x => new { x.ChoreId, x.ChildId, x.Day }).IsUnique().HasFilter("chore_id IS NOT NULL").HasDatabaseName("ix_point_entries_chore_day");
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<Child>().WithMany().HasForeignKey(x => x.ChildId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<Chore>().WithMany().HasForeignKey(x => x.ChoreId).OnDelete(DeleteBehavior.SetNull);
            e.HasOne<Reward>().WithMany().HasForeignKey(x => x.RewardId).OnDelete(DeleteBehavior.SetNull);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.ByUserId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<StudySession>(e =>
        {
            e.Property(x => x.Kind).HasConversion<string>().HasMaxLength(10);
            e.Property(x => x.Note).HasMaxLength(120);
            e.HasIndex(x => new { x.ChildId, x.StartedAt });
            // At most one running homework/reading timer per child.
            e.HasIndex(x => x.ChildId).IsUnique().HasFilter("ended_at IS NULL").HasDatabaseName("ix_study_sessions_running");
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<Child>().WithMany().HasForeignKey(x => x.ChildId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.StartedByUserId).OnDelete(DeleteBehavior.SetNull);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.EndedByUserId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<FeedingEntry>(e =>
        {
            e.Property(x => x.Kind).HasConversion<string>().HasMaxLength(10);
            e.Property(x => x.Side).HasConversion<string>().HasMaxLength(10);
            e.Property(x => x.Food).HasMaxLength(80);
            e.Property(x => x.Note).HasMaxLength(200);
            e.HasIndex(x => new { x.ChildId, x.At });
            e.HasOne<Family>().WithMany().HasForeignKey(x => x.FamilyId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<Child>().WithMany().HasForeignKey(x => x.ChildId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.ByUserId).OnDelete(DeleteBehavior.SetNull);
        });

        // Ids are generated by the domain, so EF must insert (not update) new children of tracked aggregates.
        foreach (var type in b.Model.GetEntityTypes().Where(t => typeof(Entity).IsAssignableFrom(t.ClrType)))
        {
            b.Entity(type.ClrType).Property(nameof(Entity.Id)).ValueGeneratedNever();
        }
    }
}

/// <summary>Stored response of a state-changing POST, keyed by caller scope and Idempotency-Key.</summary>
public class IdempotencyRecord
{
    public string Scope { get; set; } = default!;
    public string Key { get; set; } = default!;
    public string RequestHash { get; set; } = default!;
    public int StatusCode { get; set; }
    public string? ResponseBody { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}
