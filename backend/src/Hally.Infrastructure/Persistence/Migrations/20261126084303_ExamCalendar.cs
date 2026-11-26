using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Hally.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class ExamCalendar : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<Guid>(
                name: "exam_id",
                table: "study_sessions",
                type: "uuid",
                nullable: true);

            migrationBuilder.CreateTable(
                name: "exams",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    family_id = table.Column<Guid>(type: "uuid", nullable: false),
                    child_id = table.Column<Guid>(type: "uuid", nullable: false),
                    created_by_user_id = table.Column<Guid>(type: "uuid", nullable: true),
                    subject = table.Column<string>(type: "character varying(40)", maxLength: 40, nullable: false),
                    topics = table.Column<string>(type: "character varying(200)", maxLength: 200, nullable: true),
                    date = table.Column<DateOnly>(type: "date", nullable: false),
                    slot = table.Column<string>(type: "character varying(20)", maxLength: 20, nullable: true),
                    study_days_before = table.Column<int>(type: "integer", nullable: true),
                    event_id = table.Column<Guid>(type: "uuid", nullable: true),
                    outcome = table.Column<string>(type: "character varying(10)", maxLength: 10, nullable: true),
                    score = table.Column<int>(type: "integer", nullable: true),
                    cherries = table.Column<int>(type: "integer", nullable: false),
                    result_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    result_by_user_id = table.Column<Guid>(type: "uuid", nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_exams", x => x.id);
                    table.ForeignKey(
                        name: "fk_exams_children_child_id",
                        column: x => x.child_id,
                        principalTable: "children",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_exams_events_event_id",
                        column: x => x.event_id,
                        principalTable: "events",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_exams_families_family_id",
                        column: x => x.family_id,
                        principalTable: "families",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "fk_exams_users_created_by_user_id",
                        column: x => x.created_by_user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.SetNull);
                    table.ForeignKey(
                        name: "fk_exams_users_result_by_user_id",
                        column: x => x.result_by_user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.SetNull);
                });

            migrationBuilder.CreateIndex(
                name: "ix_study_sessions_exam_id",
                table: "study_sessions",
                column: "exam_id");

            migrationBuilder.CreateIndex(
                name: "ix_exams_child_id_date",
                table: "exams",
                columns: new[] { "child_id", "date" });

            migrationBuilder.CreateIndex(
                name: "ix_exams_created_by_user_id",
                table: "exams",
                column: "created_by_user_id");

            migrationBuilder.CreateIndex(
                name: "ix_exams_event_id",
                table: "exams",
                column: "event_id",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "ix_exams_family_id_date",
                table: "exams",
                columns: new[] { "family_id", "date" });

            migrationBuilder.CreateIndex(
                name: "ix_exams_result_by_user_id",
                table: "exams",
                column: "result_by_user_id");

            migrationBuilder.AddForeignKey(
                name: "fk_study_sessions_exams_exam_id",
                table: "study_sessions",
                column: "exam_id",
                principalTable: "exams",
                principalColumn: "id",
                onDelete: ReferentialAction.SetNull);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropForeignKey(
                name: "fk_study_sessions_exams_exam_id",
                table: "study_sessions");

            migrationBuilder.DropTable(
                name: "exams");

            migrationBuilder.DropIndex(
                name: "ix_study_sessions_exam_id",
                table: "study_sessions");

            migrationBuilder.DropColumn(
                name: "exam_id",
                table: "study_sessions");
        }
    }
}
