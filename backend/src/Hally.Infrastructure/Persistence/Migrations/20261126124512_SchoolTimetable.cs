using System;
using System.Collections.Generic;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Hally.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class SchoolTimetable : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "bag_checks",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    child_id = table.Column<Guid>(type: "uuid", nullable: false),
                    day = table.Column<DateOnly>(type: "date", nullable: false),
                    packed = table.Column<List<string>>(type: "text[]", nullable: false, defaultValueSql: "'{}'::text[]"),
                    ready_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    ready_by_user_id = table.Column<Guid>(type: "uuid", nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_bag_checks", x => x.id);
                    table.ForeignKey(
                        name: "fk_bag_checks_children_child_id",
                        column: x => x.child_id,
                        principalTable: "children",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_bag_checks_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_bag_checks_users_ready_by_user_id",
                        column: x => x.ready_by_user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.SetNull);
                });

            migrationBuilder.CreateTable(
                name: "lessons",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    child_id = table.Column<Guid>(type: "uuid", nullable: false),
                    weekday = table.Column<int>(type: "integer", nullable: false),
                    period = table.Column<int>(type: "integer", nullable: false),
                    subject = table.Column<string>(type: "character varying(40)", maxLength: 40, nullable: false),
                    items_json = table.Column<string>(type: "jsonb", nullable: false),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_lessons", x => x.id);
                    table.ForeignKey(
                        name: "fk_lessons_children_child_id",
                        column: x => x.child_id,
                        principalTable: "children",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_lessons_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "school_breaks",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    title = table.Column<string>(type: "character varying(40)", maxLength: 40, nullable: false),
                    from = table.Column<DateOnly>(type: "date", nullable: false),
                    to = table.Column<DateOnly>(type: "date", nullable: false),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_school_breaks", x => x.id);
                    table.ForeignKey(
                        name: "fk_school_breaks_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "school_plans",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    bell_times_json = table.Column<string>(type: "jsonb", nullable: false),
                    daily_items_json = table.Column<string>(type: "jsonb", nullable: false),
                    reminder_time = table.Column<TimeOnly>(type: "time without time zone", nullable: true),
                    child_phone = table.Column<bool>(type: "boolean", nullable: false),
                    quiet_on_holidays = table.Column<bool>(type: "boolean", nullable: false),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_school_plans", x => x.id);
                    table.ForeignKey(
                        name: "fk_school_plans_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "ix_bag_checks_child_id_day",
                table: "bag_checks",
                columns: new[] { "child_id", "day" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "ix_bag_checks_day",
                table: "bag_checks",
                column: "day");

            migrationBuilder.CreateIndex(
                name: "ix_bag_checks_family_id",
                table: "bag_checks",
                column: "family_id");

            migrationBuilder.CreateIndex(
                name: "ix_bag_checks_ready_by_user_id",
                table: "bag_checks",
                column: "ready_by_user_id");

            migrationBuilder.CreateIndex(
                name: "ix_lessons_child_id_weekday_period",
                table: "lessons",
                columns: new[] { "child_id", "weekday", "period" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "ix_lessons_family_id",
                table: "lessons",
                column: "family_id");

            migrationBuilder.CreateIndex(
                name: "ix_school_breaks_family_id_to",
                table: "school_breaks",
                columns: new[] { "family_id", "to" });

            migrationBuilder.CreateIndex(
                name: "ix_school_plans_family_id",
                table: "school_plans",
                column: "family_id",
                unique: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "bag_checks");

            migrationBuilder.DropTable(
                name: "lessons");

            migrationBuilder.DropTable(
                name: "school_breaks");

            migrationBuilder.DropTable(
                name: "school_plans");
        }
    }
}
