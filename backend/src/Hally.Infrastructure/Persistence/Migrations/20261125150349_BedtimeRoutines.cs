using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Hally.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class BedtimeRoutines : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "bedtime_routines",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    child_id = table.Column<Guid>(type: "uuid", nullable: false),
                    time = table.Column<TimeOnly>(type: "time without time zone", nullable: false),
                    steps_json = table.Column<string>(type: "jsonb", nullable: false),
                    enabled = table.Column<bool>(type: "boolean", nullable: false),
                    lock_until_morning = table.Column<bool>(type: "boolean", nullable: false),
                    cherries = table.Column<int>(type: "integer", nullable: false),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_bedtime_routines", x => x.id);
                    table.ForeignKey(
                        name: "fk_bedtime_routines_children_child_id",
                        column: x => x.child_id,
                        principalTable: "children",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_bedtime_routines_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "bedtime_runs",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    child_id = table.Column<Guid>(type: "uuid", nullable: false),
                    evening = table.Column<DateOnly>(type: "date", nullable: false),
                    done = table.Column<int>(type: "integer", nullable: false),
                    finished_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_bedtime_runs", x => x.id);
                    table.ForeignKey(
                        name: "fk_bedtime_runs_children_child_id",
                        column: x => x.child_id,
                        principalTable: "children",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_bedtime_runs_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "ix_bedtime_routines_child_id",
                table: "bedtime_routines",
                column: "child_id",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "ix_bedtime_routines_family_id",
                table: "bedtime_routines",
                column: "family_id");

            migrationBuilder.CreateIndex(
                name: "ix_bedtime_runs_child_id_evening",
                table: "bedtime_runs",
                columns: new[] { "child_id", "evening" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "ix_bedtime_runs_family_id",
                table: "bedtime_runs",
                column: "family_id");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "bedtime_routines");

            migrationBuilder.DropTable(
                name: "bedtime_runs");
        }
    }
}
